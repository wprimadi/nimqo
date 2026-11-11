//! Polls, places and contact cards as the timeline draws them, and voting.

use std::sync::Arc;

use nimqo_whatsapp::cards::Card;
use whatsapp_rust::Jid;
use whatsapp_rust::features::PollVoteCiphertext;
use whatsapp_rust::prelude::wa;

use crate::outbox::Sender;
use crate::{Core, CoreError};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollChoice {
    pub name: String,
    pub votes: u32,
    /// This account voted for it.
    pub mine: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PollCard {
    pub question: String,
    pub choices: Vec<PollChoice>,
    /// More than one choice may be picked.
    pub multiple: bool,
    /// People whose vote could be read.
    pub voters: u32,
    /// The poll's secret is here, so votes can be cast and read.
    pub open: bool,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlaceCard {
    pub latitude: f64,
    pub longitude: f64,
    pub name: Option<String>,
    pub address: Option<String>,
    pub live: bool,
    /// The sender's small map picture (JPEG).
    pub thumbnail: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct PersonCard {
    pub name: String,
    pub phones: Vec<String>,
    /// The phone numbers on WhatsApp, as chat ids.
    pub chats: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum MessageCard {
    Poll { poll: PollCard },
    Place { place: PlaceCard },
    People { people: Vec<PersonCard> },
}

fn poll_parts(card: &Card) -> Option<(&wa::message::PollCreationMessage, Option<&[u8]>, &str)> {
    let poll = card.message.poll_creation_message.as_option()?;
    let secret = card
        .message
        .message_context_info
        .as_option()
        .and_then(|c| c.message_secret.as_deref());
    let creator = poll
        .context_info
        .as_option()
        .and_then(|c| c.participant.as_deref())
        .unwrap_or_default();
    Some((poll, secret, creator))
}

fn option_names(poll: &wa::message::PollCreationMessage) -> Vec<String> {
    poll.options
        .iter()
        .filter_map(|o| o.option_name.clone())
        .collect()
}

/// The poll's creator, as its votes are keyed: own polls are kept without.
fn creator_jid(creator: &str, own: Option<&Jid>) -> Option<Jid> {
    if creator.is_empty() {
        return own.map(Jid::to_non_ad);
    }
    creator.parse().ok()
}

#[uniffi::export]
impl Core {
    /// Message `seq` drawn as a card: a poll with its votes so far, a place,
    /// or contacts. Nil for any other message.
    pub async fn message_card(&self, chat_id: String, seq: i64) -> Option<MessageCard> {
        let card = self.inbox.card(&chat_id, seq).ok()??;
        match card.kind.as_str() {
            "poll" => {
                let client = Arc::clone(&self.client);
                let poll = self
                    .runtime
                    .spawn(async move { poll_card(&client, &card).await })
                    .await
                    .ok()??;
                Some(MessageCard::Poll { poll })
            }
            "location" => {
                let l = card.message.location_message.as_option()?;
                Some(MessageCard::Place {
                    place: PlaceCard {
                        latitude: l.degrees_latitude?,
                        longitude: l.degrees_longitude?,
                        name: l.name.clone().filter(|s| !s.is_empty()),
                        address: l
                            .address
                            .clone()
                            .or_else(|| l.comment.clone())
                            .filter(|s| !s.is_empty()),
                        live: l.is_live == Some(true),
                        thumbnail: l.jpeg_thumbnail.clone(),
                    },
                })
            }
            "contact" => {
                let cards = card.message.contacts_array_message.as_option()?;
                let people = cards
                    .contacts
                    .iter()
                    .map(|c| person(c.display_name.as_deref(), c.vcard.as_deref()))
                    .collect();
                Some(MessageCard::People { people })
            }
            _ => None,
        }
    }

    /// Votes in poll `seq` for `choices` (by name); none takes the vote back.
    ///
    /// # Errors
    /// `SendRefused` when the poll cannot be voted in from here, or the vote
    /// is not sent.
    pub async fn vote_in_poll(
        &self,
        chat_id: String,
        seq: i64,
        choices: Vec<String>,
    ) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        let chat = Sender::may_send(&chat_id)?;
        let card = self
            .inbox
            .card(&chat_id, seq)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
            .filter(|c| c.kind == "poll")
            .ok_or_else(|| refused("This poll is no longer here."))?;
        let (poll, secret, creator) = poll_parts(&card).ok_or_else(|| refused("Not a poll."))?;
        let secret = secret
            .ok_or_else(|| {
                refused("This poll came without its key, so it can't be voted in here.")
            })?
            .to_vec();
        let names = option_names(poll);
        let single = poll.selectable_options_count.unwrap_or(0) == 1;
        if choices.iter().any(|c| !names.contains(c)) || (single && choices.len() > 1) {
            return Err(refused("That is not a choice in this poll."));
        }
        let (client, inbox, id, creator, chat_key) = (
            Arc::clone(&self.client),
            self.inbox.clone(),
            card.id.clone(),
            creator.to_owned(),
            chat_id.clone(),
        );
        self.on_runtime(async move {
            let own = client.pn().ok_or_else(|| refused("Not signed in."))?;
            let creator =
                creator_jid(&creator, Some(&own)).ok_or_else(|| refused("Not a poll."))?;
            let sent = client
                .polls()
                .vote_raw(chat, &id, &creator, &secret, &choices)
                .await
                .map_err(|e| refused(&format!("Vote not sent: {e}")))?;
            let voter = sent
                .message
                .poll_update_message
                .as_option()
                .map(|_| own.to_non_ad().to_string())
                .unwrap_or_default();
            if let Err(e) = inbox.record_own_vote(&chat_key, &sent.message, &voter) {
                log::warn!("own vote not kept: {e:#}");
            }
            Ok(())
        })
        .await?;
        self.inbox.notify_changed(vec![chat_id]);
        Ok(())
    }
}

async fn poll_card(client: &whatsapp_rust::Client, card: &Card) -> Option<PollCard> {
    let (poll, secret, creator) = poll_parts(card)?;
    let names = option_names(poll);
    let hashes: Vec<[u8; 32]> = names
        .iter()
        .map(|n| nimqo_whatsapp::cards::option_hash(n))
        .collect();
    let mut tally = vec![0u32; names.len()];
    let mut mine = vec![false; names.len()];
    let mut counted = 0u32;
    let single = poll.selectable_options_count == Some(1);
    let own = client.pn();
    if let (Some(secret), Some(creator)) = (secret, creator_jid(creator, own.as_ref())) {
        for vote in &card.votes {
            let picked: Vec<Vec<u8>> = if vote.iv.is_empty() {
                vote.payload
                    .as_chunks::<32>()
                    .0
                    .iter()
                    .map(|h| h.to_vec())
                    .collect()
            } else {
                let Ok(voter) = vote.voter_jid.parse::<Jid>() else {
                    continue;
                };
                let sealed = PollVoteCiphertext {
                    enc_payload: &vote.payload,
                    enc_iv: &vote.iv,
                };
                let Ok(picked) = client
                    .polls()
                    .decrypt_vote_raw(sealed, secret, &card.id, &creator, &voter)
                    .await
                else {
                    continue;
                };
                picked
            };
            // Each choice once; a one-answer poll counts one at most.
            let mut chosen: Vec<usize> = picked
                .iter()
                .filter_map(|hash| hashes.iter().position(|h| h.as_slice() == hash.as_slice()))
                .collect();
            chosen.sort_unstable();
            chosen.dedup();
            if single {
                chosen.truncate(1);
            }
            if chosen.is_empty() {
                continue;
            }
            counted += 1;
            for i in chosen {
                tally[i] += 1;
                mine[i] |= vote.voter == nimqo_whatsapp::inbox::ME;
            }
        }
    }
    Some(PollCard {
        question: poll.name.clone().unwrap_or_default(),
        choices: names
            .into_iter()
            .zip(tally)
            .zip(mine)
            .map(|((name, votes), mine)| PollChoice { name, votes, mine })
            .collect(),
        multiple: poll.selectable_options_count.unwrap_or(0) != 1,
        voters: counted,
        open: secret.is_some(),
    })
}

/// A contact from its vCard: the name, each phone number, and those on
/// WhatsApp (`waid`) as chat ids.
fn person(display: Option<&str>, vcard: Option<&str>) -> PersonCard {
    let mut name = display.unwrap_or_default().to_owned();
    let (mut phones, mut chats) = (Vec::new(), Vec::new());
    // Folded lines continue with a space or a tab.
    let unfolded = vcard
        .unwrap_or_default()
        .replace("\r\n ", "")
        .replace("\r\n\t", "")
        .replace("\n ", "");
    for line in unfolded.lines().take(256) {
        let Some((key, value)) = line.split_once(':') else {
            continue;
        };
        let mut params = key.split(';');
        let field = params.next().unwrap_or_default();
        let field = field
            .rsplit('.')
            .next()
            .unwrap_or(field)
            .to_ascii_uppercase();
        let value = value.trim();
        match field.as_str() {
            "FN" if name.is_empty() => value.clone_into(&mut name),
            "TEL" if !value.is_empty() && phones.len() < 16 => {
                phones.push(value.to_owned());
                let waid = params
                    .find_map(|p| p.strip_prefix("waid=").or_else(|| p.strip_prefix("WAID=")));
                if let Some(waid) = waid.filter(|w| {
                    (5..=20).contains(&w.len()) && w.bytes().all(|b| b.is_ascii_digit())
                }) {
                    chats.push(format!("{waid}@s.whatsapp.net"));
                }
            }
            _ => {}
        }
    }
    PersonCard {
        name,
        phones,
        chats,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_vcard_gives_name_numbers_and_whatsapp_chats() {
        let vcard = "BEGIN:VCARD\r\nVERSION:3.0\r\nN:;Ana;;;\r\nFN:Ana Putri\r\n\
                     item1.TEL;waid=6281234567890:+62 812-3456-7890\r\nitem1.X-ABLabel:Mobile\r\n\
                     TEL;TYPE=HOME:+62 21 555\r\nEND:VCARD";
        let p = person(None, Some(vcard));
        assert_eq!(p.name, "Ana Putri");
        assert_eq!(p.phones, ["+62 812-3456-7890", "+62 21 555"]);
        assert_eq!(p.chats, ["6281234567890@s.whatsapp.net"]);
        // A waid that is not a number names no chat.
        let odd = person(Some("X"), Some("TEL;waid=../x:1"));
        assert_eq!((odd.name.as_str(), odd.chats.len()), ("X", 0));
    }
}
