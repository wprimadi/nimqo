//! History sync import (plan 10.4): the phone sends recent chats after
//! pairing and on demand. Messages go into the same store as live ones;
//! the (chat, id) key makes overlap with live delivery harmless.

use anyhow::Result;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::types::events::LazyHistorySync;

use crate::inbox::{Inbox, ME, Row, STATUS, STATUS_LIFETIME, classify};

/// Stores every displayable message in one history chunk, one transaction
/// per conversation. Returns the number of messages read.
///
/// ponytail: history is not a durable event; a crash mid-import loses the
/// rest of that chunk until the phone resends it.
///
/// # Errors
/// The chunk cannot be inflated or the store cannot be written.
pub fn import(inbox: &Inbox, sync: &LazyHistorySync) -> Result<usize> {
    let mut stream = sync.stream();
    let (mut total, mut chats, mut pairs, mut saved) = (0, Vec::new(), Vec::new(), 0);
    while let Some(conv) = stream.next_conversation()? {
        pairs.extend(lid_pair(conv.lid_jid.as_deref(), conv.pn_jid.as_deref()));
        if conv.id.ends_with("@s.whatsapp.net") {
            pairs.extend(lid_pair(conv.lid_jid.as_deref(), Some(&conv.id)));
        }
        if conv.id.ends_with("@lid") {
            pairs.extend(lid_pair(Some(&conv.id), conv.pn_jid.as_deref()));
        }
        let Some(chat) = chat_id(&conv) else { continue };
        let rows: Vec<Row> = conv
            .messages
            .iter()
            .filter_map(|m| m.message.as_option())
            .filter_map(|m| row(&chat, m))
            .collect();
        total += rows.len();
        // Groups: the subject. People: the name saved on the phone, which
        // the address book sync can lack. Not display_name: it can be the
        // person's own profile name, shown unmarked it would pass as saved.
        let votes: Vec<crate::effects::Effect> = conv
            .messages
            .iter()
            .filter_map(|m| m.message.as_option())
            .flat_map(|m| history_votes(&chat, m))
            .collect();
        let name = conv.name.filter(|n| !n.trim().is_empty());
        saved += usize::from(name.is_some() && !chat.ends_with("@g.us"));
        inbox.import(&chat, name, rows)?;
        if !votes.is_empty() {
            inbox.commit(Vec::new(), &votes)?;
        }
        if let Some(seconds) = conv.ephemeral_expiration {
            let timer = crate::effects::Effect::Timer {
                chat: chat.clone(),
                seconds,
            };
            inbox.commit(Vec::new(), &[timer])?;
        }
        chats.push(chat);
    }
    let rest = stream.remainder()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
    let statuses: Vec<Row> = rest
        .status_v3_messages
        .iter()
        .filter_map(|m| status_row(m, now))
        .collect();
    if !statuses.is_empty() {
        log::info!("{} status update(s) from history", statuses.len());
        total += statuses.len();
        inbox.commit(statuses, &[])?;
        chats.push(STATUS.to_owned());
    }
    for m in rest.phone_number_to_lid_mappings {
        pairs.extend(lid_pair(m.lid_jid.as_deref(), m.pn_jid.as_deref()));
    }
    inbox.record_lids(&pairs)?;
    if saved > 0 {
        log::info!("{saved} saved name(s) of people from history");
    }
    let names: Vec<(String, String)> = rest
        .pushnames
        .into_iter()
        .filter_map(|p| {
            Some((
                strip_device(&p.id?),
                p.pushname.filter(|n| !n.trim().is_empty())?,
            ))
        })
        .collect();
    if !names.is_empty() {
        log::info!("{} profile name(s) from history", names.len());
        inbox.record_push_names(&names)?;
        // Chat titles may change for chats not in this chunk.
        chats.push(String::new());
    }
    inbox.notify(chats);
    Ok(total)
}

fn lid_pair(lid: Option<&str>, pn: Option<&str>) -> Option<(String, String)> {
    let (lid, pn) = (strip_device(lid?), strip_device(pn?));
    (lid.ends_with("@lid") && pn.ends_with("@s.whatsapp.net")).then_some((lid, pn))
}

/// Same filing rule as live messages: LID chats under the phone number.
fn chat_id(conv: &wa::Conversation) -> Option<String> {
    let id = conv.id.as_str();
    if id.ends_with("@broadcast") || id.ends_with("@newsletter") {
        return None;
    }
    if id.ends_with("@lid")
        && let Some(pn) = conv.pn_jid.as_deref()
    {
        return Some(strip_device(pn));
    }
    Some(strip_device(id))
}

/// `628…:12@s.whatsapp.net` -> `628…@s.whatsapp.net`.
fn strip_device(jid: &str) -> String {
    match jid.split_once('@') {
        Some((user, server)) => {
            let user = user.split_once(':').map_or(user, |(u, _)| u);
            format!("{user}@{server}")
        }
        None => jid.to_owned(),
    }
}

fn row(chat: &str, m: &wa::WebMessageInfo) -> Option<Row> {
    let key = m.key.as_option()?;
    let (kind, body) = classify(m.message.as_option()?)?;
    let from_me = key.from_me.unwrap_or(false);
    // Same normalization as live messages (`inbox::sender_key`).
    // ponytail: a group member addressed by LID here but by phone number
    // live can be stored twice around pairing; resolve via the LID map later.
    let sender = if from_me {
        ME
    } else {
        key.participant
            .as_deref()
            .or(m.participant.as_deref())
            .unwrap_or(chat)
    };
    Some(Row {
        chat: chat.to_owned(),
        sender: strip_device(sender),
        id: key.id.clone()?,
        ts: i64::try_from(m.message_timestamp?).ok()?,
        body,
        from_me,
        kind: kind.to_owned(),
        sender_name: m.push_name.clone().unwrap_or_default(),
        status: if from_me {
            history_status(m.status)
        } else {
            ""
        },
        media: crate::inbox::media_of(m.message.as_option()?)
            .or_else(|| {
                let creator = if from_me {
                    String::new()
                } else {
                    strip_device(sender)
                };
                crate::cards::card_of(m.message.as_option()?, &creator)
            })
            .or_else(|| crate::links::link_of(m.message.as_option()?)),
        quote: crate::replies::quote_of(m.message.as_option()?),
        forwarded: crate::inbox::is_forwarded(m.message.as_option()?),
        // ponytail: history counts as read; the conversation's unread
        // count could mark its newest messages unread instead.
        read: true,
        expires_at: m
            .ephemeral_duration
            .filter(|d| *d > 0)
            .and_then(|d| Some(i64::try_from(m.message_timestamp?).ok()? + i64::from(d))),
    })
}

/// The votes the phone already holds for a poll in history. They come
/// open (the chosen options' hashes), not sealed as live votes do, so
/// they are kept open: an empty IV marks them (see `cards::SealedVote`).
fn history_votes(chat: &str, m: &wa::WebMessageInfo) -> Vec<crate::effects::Effect> {
    let Some(target) = m.key.as_option().and_then(|k| k.id.clone()) else {
        return Vec::new();
    };
    m.poll_updates
        .iter()
        .filter_map(|u| {
            let key = u.poll_update_message_key.as_option()?;
            let voter = if key.from_me.unwrap_or(false) {
                ME.to_owned()
            } else {
                strip_device(key.participant.as_deref().or(key.remote_jid.as_deref())?)
            };
            let picked = &u.vote.as_option()?.selected_options;
            let payload = picked
                .iter()
                .filter(|h| h.len() == 32)
                .flatten()
                .copied()
                .collect();
            Some(crate::effects::Effect::Vote {
                chat: chat.to_owned(),
                voter: voter.clone(),
                vote: crate::cards::Vote {
                    target: target.clone(),
                    voter_jid: voter,
                    payload,
                    iv: Vec::new(),
                    ts: u.sender_timestamp_ms.unwrap_or(0),
                },
            })
        })
        .collect()
}

/// A status update still up (`now`), as a live one is kept: gone a day
/// after it was posted, and not yet viewed here unless it is our own.
fn status_row(m: &wa::WebMessageInfo, now: i64) -> Option<Row> {
    let mut row = row(STATUS, m)?;
    let ends = row.ts + STATUS_LIFETIME;
    if ends <= now {
        return None;
    }
    row.expires_at = Some(ends);
    row.read = row.from_me;
    Some(row)
}

/// Never "pending": that would put the phone's message in our outbox.
fn history_status(status: Option<wa::web_message_info::Status>) -> &'static str {
    use wa::web_message_info::Status;
    match status {
        Some(Status::ERROR) => "failed",
        Some(Status::DELIVERY_ACK) => "delivered",
        Some(Status::READ | Status::PLAYED) => "read",
        _ => "sent",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lid_conversations_use_the_phone_number_and_devices_are_dropped() {
        let conv = |id: &str, pn: Option<&str>| {
            let mut c = wa::Conversation::default();
            c.id = id.into();
            c.pn_jid = pn.map(Into::into);
            c
        };
        assert_eq!(
            chat_id(&conv("9@lid", Some("62811:3@s.whatsapp.net"))).as_deref(),
            Some("62811@s.whatsapp.net")
        );
        assert_eq!(chat_id(&conv("9@lid", None)).as_deref(), Some("9@lid"));
        assert_eq!(chat_id(&conv("status@broadcast", None)), None);
        assert_eq!(
            chat_id(&conv("1-2@g.us", None)).as_deref(),
            Some("1-2@g.us")
        );
    }

    #[test]
    fn history_brings_poll_votes_open_keyed_by_voter() {
        use whatsapp_rust::buffa::MessageField;
        let update = |from_me: bool, who: Option<&str>, picked: Vec<Vec<u8>>| {
            let mut key = wa::MessageKey::default();
            key.from_me = Some(from_me);
            key.participant = who.map(Into::into);
            let mut vote = wa::message::PollVoteMessage::default();
            vote.selected_options = picked;
            let mut u = wa::PollUpdate::default();
            u.poll_update_message_key = MessageField::some(key);
            u.vote = MessageField::some(vote);
            u.sender_timestamp_ms = Some(7);
            u
        };
        let mut key = wa::MessageKey::default();
        key.id = Some("poll1".into());
        let mut m = wa::WebMessageInfo::default();
        m.key = MessageField::some(key);
        m.poll_updates = vec![
            update(
                false,
                Some("62811:4@s.whatsapp.net"),
                vec![vec![1; 32], vec![2; 32], vec![3; 5]],
            ),
            update(true, None, vec![]),
        ];
        let votes = history_votes("1-2@g.us", &m);
        assert_eq!(votes.len(), 2);
        let crate::effects::Effect::Vote { chat, voter, vote } = &votes[0] else {
            panic!("a vote")
        };
        assert_eq!(
            (chat.as_str(), voter.as_str()),
            ("1-2@g.us", "62811@s.whatsapp.net")
        );
        assert_eq!(
            (
                vote.target.as_str(),
                vote.payload.len(),
                vote.iv.len(),
                vote.ts
            ),
            ("poll1", 64, 0, 7)
        );
        let crate::effects::Effect::Vote { voter, vote, .. } = &votes[1] else {
            panic!("a vote")
        };
        assert_eq!(
            (voter.as_str(), vote.payload.len()),
            (ME, 0),
            "an own vote taken back"
        );
    }

    #[test]
    fn history_statuses_last_a_day_and_wait_to_be_viewed() {
        use whatsapp_rust::buffa::MessageField;
        use whatsapp_rust::prelude::MessageBuilderExt as _;
        let status = |ts: u64| {
            let mut key = wa::MessageKey::default();
            key.id = Some(format!("s{ts}"));
            key.remote_jid = Some(STATUS.into());
            key.participant = Some("62811:2@s.whatsapp.net".into());
            let mut m = wa::WebMessageInfo::default();
            m.key = MessageField::some(key);
            m.message = MessageField::some(wa::Message::text("hi".to_owned()));
            m.message_timestamp = Some(ts);
            m
        };
        let now = 200_000;
        let row = status_row(&status(150_000), now).unwrap();
        assert_eq!(
            (row.chat.as_str(), row.sender.as_str()),
            (STATUS, "62811@s.whatsapp.net")
        );
        assert_eq!(
            (row.expires_at, row.read),
            (Some(150_000 + STATUS_LIFETIME), false)
        );
        assert!(status_row(&status(100_000), now).is_none(), "already gone");
    }
}
