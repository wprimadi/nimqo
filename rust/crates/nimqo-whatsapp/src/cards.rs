//! Polls, places and contact cards: kept whole (as `media`) so the timeline
//! can draw them as they are, not as a line of text. Poll votes arrive
//! encrypted for the poll; they are kept so, and opened when shown.

use diesel::sql_types::{BigInt, Binary, Bool, Text};
use diesel::{OptionalExtension, QueryResult, RunQueryDsl, SqliteConnection};
use whatsapp_rust::buffa::{Message as _, MessageField};
use whatsapp_rust::prelude::{MessageExt as _, wa};

use crate::inbox::Inbox;

pub const KINDS: [&str; 4] = ["poll", "location", "contact", "buttons"];

/// At most this many contacts in one card, options in one poll.
const MAX_ITEMS: usize = 64;

fn poll_of(b: &wa::Message) -> Option<&wa::message::PollCreationMessage> {
    [
        &b.poll_creation_message,
        &b.poll_creation_message_v2,
        &b.poll_creation_message_v3,
        &b.poll_creation_message_v5,
    ]
    .into_iter()
    .find_map(|p| p.as_option())
}

/// How a vote names a choice.
#[must_use]
pub fn option_hash(name: &str) -> [u8; 32] {
    use sha2::Digest as _;
    sha2::Sha256::digest(name.as_bytes()).into()
}

/// The kind and the line that stands for it in the chat list and search.
pub(crate) fn classify(b: &wa::Message) -> Option<(&'static str, Option<String>)> {
    let some = |s: &Option<String>| s.clone().filter(|s| !s.is_empty());
    if let Some(p) = poll_of(b) {
        return Some((
            "poll",
            Some(format!("📊 {}", p.name.clone().unwrap_or_default())),
        ));
    }
    if let Some(c) = b.contact_message.as_option() {
        return Some((
            "contact",
            Some(format!("👤 {}", some(&c.display_name).unwrap_or_default())),
        ));
    }
    if let Some(c) = b.contacts_array_message.as_option() {
        let name =
            some(&c.display_name).unwrap_or_else(|| format!("{} contacts", c.contacts.len()));
        return Some(("contact", Some(format!("👤 {name}"))));
    }
    if let Some(l) = b.location_message.as_option() {
        let name = some(&l.name).unwrap_or_else(|| "Location".to_owned());
        return Some(("location", Some(format!("📍 {name}"))));
    }
    if b.live_location_message.as_option().is_some() {
        return Some(("location", Some("📍 Live location".to_owned())));
    }
    crate::buttons::classify(b)
}

/// What is kept of a card. A poll keeps its secret (to open the votes) in
/// the context info, and its creator (`creator`, raw: votes are keyed to
/// the address it was made under) as the context's participant; empty for
/// own polls. A live location is kept as the place it was last at.
pub(crate) fn card_of(message: &wa::Message, creator: &str) -> Option<Vec<u8>> {
    let b = message.get_base_message();
    if poll_of(b).is_none() && crate::buttons::classify(b).is_some() {
        return crate::buttons::kept(b);
    }
    let mut kept = wa::Message::default();
    if let Some(p) = poll_of(b) {
        let mut poll = p.clone();
        let mut context = wa::ContextInfo::default();
        context.participant = Some(creator.to_owned());
        poll.context_info = MessageField::some(context);
        poll.options.truncate(MAX_ITEMS);
        kept.poll_creation_message = MessageField::some(poll);
        let secret = message
            .message_context_info
            .as_option()
            .and_then(|c| c.message_secret.clone());
        if let Some(secret) = secret {
            let mut info = wa::MessageContextInfo::default();
            info.message_secret = Some(secret);
            kept.message_context_info = MessageField::some(info);
        }
    } else if let Some(c) = b.contact_message.as_option() {
        let mut card = wa::message::ContactsArrayMessage::default();
        card.display_name.clone_from(&c.display_name);
        card.contacts.push(contact(c));
        kept.contacts_array_message = MessageField::some(card);
    } else if let Some(c) = b.contacts_array_message.as_option() {
        let mut card = wa::message::ContactsArrayMessage::default();
        card.display_name.clone_from(&c.display_name);
        card.contacts = c.contacts.iter().take(MAX_ITEMS).map(contact).collect();
        kept.contacts_array_message = MessageField::some(card);
    } else if let Some(l) = b.location_message.as_option() {
        let mut place = l.clone();
        place.context_info = MessageField::none();
        kept.location_message = MessageField::some(place);
    } else {
        let l = b.live_location_message.as_option()?;
        let mut place = wa::message::LocationMessage::default();
        place.degrees_latitude = l.degrees_latitude;
        place.degrees_longitude = l.degrees_longitude;
        place.comment.clone_from(&l.caption);
        place.jpeg_thumbnail.clone_from(&l.jpeg_thumbnail);
        place.is_live = Some(true);
        kept.location_message = MessageField::some(place);
    }
    Some(kept.encode_to_vec())
}

fn contact(c: &wa::message::ContactMessage) -> wa::message::ContactMessage {
    let mut kept = wa::message::ContactMessage::default();
    kept.display_name.clone_from(&c.display_name);
    kept.vcard.clone_from(&c.vcard);
    kept
}

/// A vote: the poll's id, the voter (as stored, and as addressed: votes are
/// keyed to that), and the sealed choice.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Vote {
    pub target: String,
    pub voter_jid: String,
    pub payload: Vec<u8>,
    pub iv: Vec<u8>,
    pub ts: i64,
}

impl Vote {
    pub(crate) fn parse(b: &wa::Message, voter_jid: String) -> Option<Self> {
        let u = b.poll_update_message.as_option()?;
        let vote = u.vote.as_option()?;
        // Sealed votes carry a 12-byte IV; an empty one marks an open vote
        // from history, which a live message must not pass for.
        if vote.enc_iv.as_ref().is_none_or(|iv| iv.len() != 12) {
            return None;
        }
        Some(Self {
            target: u.poll_creation_message_key.as_option()?.id.clone()?,
            voter_jid,
            payload: vote.enc_payload.clone()?,
            iv: vote.enc_iv.clone()?,
            ts: u.sender_timestamp_ms.unwrap_or(0),
        })
    }

    /// The newest vote of each voter stands, an empty one taking it back.
    pub(crate) fn apply(
        &self,
        c: &mut SqliteConnection,
        chat: &str,
        voter: &str,
    ) -> QueryResult<usize> {
        diesel::sql_query(
            "INSERT INTO poll_votes (chat, target, voter, voter_jid, payload, iv, ts)
             VALUES (?, ?, ?, ?, ?, ?, ?)
             ON CONFLICT (chat, target, voter) DO UPDATE SET
               voter_jid = excluded.voter_jid, payload = excluded.payload,
               iv = excluded.iv, ts = excluded.ts
             WHERE excluded.ts >= poll_votes.ts",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(&self.target)
        .bind::<Text, _>(voter)
        .bind::<Text, _>(&self.voter_jid)
        .bind::<Binary, _>(&self.payload)
        .bind::<Binary, _>(&self.iv)
        .bind::<BigInt, _>(self.ts)
        .execute(c)
    }
}

/// A card as stored, with what a poll needs to open its votes.
pub struct Card {
    pub kind: String,
    pub id: String,
    pub from_me: bool,
    pub message: wa::Message,
    pub votes: Vec<SealedVote>,
}

/// A vote as kept: sealed for the poll, or open (the chosen options'
/// hashes, 32 bytes each, back to back) when `iv` is empty, as history
/// brings them.
pub struct SealedVote {
    /// "me" for own votes.
    pub voter: String,
    pub voter_jid: String,
    pub payload: Vec<u8>,
    pub iv: Vec<u8>,
}

impl Inbox {
    /// Message `seq` of `chat` when it is a poll, place or contact card.
    ///
    /// # Errors
    /// The store cannot be read.
    pub fn card(&self, chat: &str, seq: i64) -> anyhow::Result<Option<Card>> {
        #[derive(diesel::QueryableByName)]
        struct Row {
            #[diesel(sql_type = Text)]
            kind: String,
            #[diesel(sql_type = Text)]
            id: String,
            #[diesel(sql_type = Bool)]
            from_me: bool,
            #[diesel(sql_type = Binary)]
            media: Vec<u8>,
        }
        #[derive(diesel::QueryableByName)]
        struct VoteRow {
            #[diesel(sql_type = Text)]
            voter: String,
            #[diesel(sql_type = Text)]
            voter_jid: String,
            #[diesel(sql_type = Binary)]
            payload: Vec<u8>,
            #[diesel(sql_type = Binary)]
            iv: Vec<u8>,
        }
        let mut conn = self.lock()?;
        let row: Option<Row> = diesel::sql_query(
            "SELECT kind, id, from_me, media FROM messages
             WHERE rowid = ? AND chat = ? AND media IS NOT NULL AND kind IN ('poll', 'location', 'contact', 'buttons')",
        )
        .bind::<BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .get_result(&mut *conn)
        .optional()?;
        let Some(row) = row else { return Ok(None) };
        let votes = if row.kind == "poll" {
            diesel::sql_query(
                "SELECT voter, voter_jid, payload, iv FROM poll_votes WHERE chat = ? AND target = ? LIMIT 1024",
            )
            .bind::<Text, _>(chat)
            .bind::<Text, _>(&row.id)
            .load::<VoteRow>(&mut *conn)?
            .into_iter()
            .map(|v| SealedVote {
                voter: v.voter,
                voter_jid: v.voter_jid,
                payload: v.payload,
                iv: v.iv,
            })
            .collect()
        } else {
            Vec::new()
        };
        Ok(Some(Card {
            message: wa::Message::decode_from_slice(&row.media)?,
            kind: row.kind,
            id: row.id,
            from_me: row.from_me,
            votes,
        }))
    }

    /// Keeps a vote sent from here, as one from the phone would be.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn record_own_vote(
        &self,
        chat: &str,
        sent: &wa::Message,
        own_jid: &str,
    ) -> anyhow::Result<()> {
        let Some(vote) = Vote::parse(sent, own_jid.to_owned()) else {
            return Ok(());
        };
        let mut conn = self.lock()?;
        vote.apply(&mut conn, chat, crate::inbox::ME)?;
        Ok(())
    }
}

/// WhatsApp's own limits for a poll.
const MAX_QUESTION: usize = 255;
const MAX_OPTION: usize = 100;
const MAX_OPTIONS: usize = 12;

/// An own poll, as kept (see `card_of`): `question` and 2 to 12 distinct
/// `options`, trimmed; one choice each, or any number when `multiple`.
/// Its secret, which voters need, is made here.
///
/// # Errors
/// Why the poll is not one WhatsApp takes.
pub fn new_poll(question: &str, options: &[String], multiple: bool) -> anyhow::Result<Vec<u8>> {
    let question = question.trim();
    let options: Vec<String> = options.iter().map(|o| o.trim().to_owned()).collect();
    anyhow::ensure!(!question.is_empty(), "Ask a question.");
    anyhow::ensure!(
        question.chars().count() <= MAX_QUESTION,
        "The question is too long."
    );
    anyhow::ensure!(
        (2..=MAX_OPTIONS).contains(&options.len()),
        "A poll has 2 to {MAX_OPTIONS} options."
    );
    anyhow::ensure!(
        options
            .iter()
            .all(|o| !o.is_empty() && o.chars().count() <= MAX_OPTION),
        "Each option needs 1 to {MAX_OPTION} characters."
    );
    let distinct: std::collections::HashSet<&String> = options.iter().collect();
    anyhow::ensure!(
        distinct.len() == options.len(),
        "Each option must be different."
    );
    let mut poll = wa::message::PollCreationMessage::default();
    poll.name = Some(question.to_owned());
    poll.options = options
        .into_iter()
        .map(|name| {
            let mut option = wa::message::poll_creation_message::Option::default();
            option.option_name = Some(name);
            option
        })
        .collect();
    // As WhatsApp Web: 1 for one choice, 0 for any number.
    poll.selectable_options_count = Some(u32::from(!multiple));
    poll.poll_content_type = Some(wa::message::PollContentType::TEXT);
    let mut secret = vec![0; 32];
    crate::vault::fill_random(&mut secret)?;
    let mut message = wa::Message::default();
    message.poll_creation_message = MessageField::some(poll);
    let mut info = wa::MessageContextInfo::default();
    info.message_secret = Some(secret);
    message.message_context_info = MessageField::some(info);
    card_of(&message, "").ok_or_else(|| anyhow::anyhow!("poll not kept"))
}

/// An own poll as kept, as it is sent: without what was added to keep it,
/// one-choice polls in the form WhatsApp Web sends.
#[must_use]
pub fn poll_to_send(kept: &[u8]) -> Option<wa::Message> {
    let kept = wa::Message::decode_from_slice(kept).ok()?;
    let mut poll = kept.poll_creation_message.as_option()?.clone();
    kept.message_context_info
        .as_option()?
        .message_secret
        .as_ref()?;
    poll.context_info = MessageField::none();
    let mut message = wa::Message::default();
    if poll.selectable_options_count == Some(1) {
        message.poll_creation_message_v3 = MessageField::some(poll);
    } else {
        message.poll_creation_message = MessageField::some(poll);
    }
    message.message_context_info = kept.message_context_info.clone();
    Some(message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_poll_keeps_its_options_secret_and_creator() {
        let mut poll = wa::message::PollCreationMessage::default();
        poll.name = Some("Lunch?".into());
        for name in ["Yes", "No"] {
            let mut o = wa::message::poll_creation_message::Option::default();
            o.option_name = Some(name.into());
            poll.options.push(o);
        }
        let mut m = wa::Message::default();
        m.poll_creation_message_v3 = MessageField::some(poll);
        let mut info = wa::MessageContextInfo::default();
        info.message_secret = Some(vec![7; 32]);
        m.message_context_info = MessageField::some(info);

        assert_eq!(classify(&m), Some(("poll", Some("📊 Lunch?".into()))));
        let kept = wa::Message::decode_from_slice(&card_of(&m, "1@lid").unwrap()).unwrap();
        let p = kept.poll_creation_message.as_option().unwrap();
        assert_eq!(p.options.len(), 2);
        assert_eq!(
            p.context_info.as_option().unwrap().participant.as_deref(),
            Some("1@lid")
        );
        let secret = kept
            .message_context_info
            .as_option()
            .unwrap()
            .message_secret
            .clone();
        assert_eq!(secret, Some(vec![7; 32]));
    }

    #[test]
    fn a_live_location_is_kept_as_its_last_place() {
        let mut live = wa::message::LiveLocationMessage::default();
        live.degrees_latitude = Some(-6.2);
        live.degrees_longitude = Some(106.8);
        let mut m = wa::Message::default();
        m.live_location_message = MessageField::some(live);
        assert_eq!(
            classify(&m),
            Some(("location", Some("📍 Live location".into())))
        );
        let kept = wa::Message::decode_from_slice(&card_of(&m, "").unwrap()).unwrap();
        let place = kept.location_message.as_option().unwrap();
        assert_eq!(
            (place.degrees_latitude, place.is_live),
            (Some(-6.2), Some(true))
        );
    }

    #[test]
    fn own_polls_are_checked_kept_with_a_secret_and_sent_bare() {
        let opts = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert!(
            new_poll(" ", &opts(&["a", "b"]), false).is_err(),
            "no question"
        );
        assert!(new_poll("Q", &opts(&["a"]), false).is_err(), "one option");
        assert!(
            new_poll("Q", &opts(&["a", " a "]), false).is_err(),
            "same option"
        );
        assert!(
            new_poll("Q", &opts(&["a", ""]), false).is_err(),
            "empty option"
        );
        let kept = new_poll(" Lunch? ", &opts(&["Rice", "Noodles "]), false).unwrap();
        let sent = poll_to_send(&kept).unwrap();
        let poll = sent.poll_creation_message_v3.as_option().unwrap();
        assert_eq!(poll.name.as_deref(), Some("Lunch?"));
        assert_eq!(poll.options[1].option_name.as_deref(), Some("Noodles"));
        assert!(
            poll.context_info.as_option().is_none(),
            "the kept creator stays here"
        );
        let secret = sent
            .message_context_info
            .as_option()
            .unwrap()
            .message_secret
            .clone()
            .unwrap();
        assert_eq!(secret.len(), 32);
        let any = poll_to_send(&new_poll("Q", &opts(&["a", "b"]), true).unwrap()).unwrap();
        assert_eq!(
            any.poll_creation_message
                .as_option()
                .unwrap()
                .selectable_options_count,
            Some(0)
        );
        assert_ne!(
            any.message_context_info
                .as_option()
                .unwrap()
                .message_secret
                .as_ref(),
            Some(&secret)
        );
    }

    #[test]
    fn a_live_vote_must_be_sealed() {
        let vote = |iv: Option<Vec<u8>>| {
            let mut key = wa::MessageKey::default();
            key.id = Some("poll1".into());
            let mut enc = wa::message::PollEncValue::default();
            enc.enc_payload = Some(vec![1; 40]);
            enc.enc_iv = iv;
            let mut update = wa::message::PollUpdateMessage::default();
            update.poll_creation_message_key = MessageField::some(key);
            update.vote = MessageField::some(enc);
            let mut m = wa::Message::default();
            m.poll_update_message = MessageField::some(update);
            Vote::parse(&m, "62811@s.whatsapp.net".into())
        };
        assert!(vote(Some(vec![0; 12])).is_some());
        assert!(
            vote(Some(Vec::new())).is_none(),
            "would pass for an open vote"
        );
        assert!(vote(None).is_none());
    }
}
