//! History sync import (plan 10.4): the phone sends recent chats after
//! pairing and on demand. Messages go into the same store as live ones;
//! the (chat, id) key makes overlap with live delivery harmless.

use anyhow::Result;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::types::events::LazyHistorySync;

use crate::inbox::{Inbox, Row, classify};

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
    let (mut total, mut chats) = (0, Vec::new());
    while let Some(conv) = stream.next_conversation()? {
        let Some(chat) = chat_id(&conv) else { continue };
        let rows: Vec<Row> = conv
            .messages
            .iter()
            .filter_map(|m| m.message.as_option())
            .filter_map(|m| row(&chat, m))
            .collect();
        total += rows.len();
        let name = chat.ends_with("@g.us").then_some(conv.name).flatten();
        inbox.import(&chat, name, rows)?;
        chats.push(chat);
    }
    inbox.notify(chats);
    Ok(total)
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
    let sender = key
        .participant
        .as_deref()
        .or(m.participant.as_deref())
        .unwrap_or(chat);
    Some(Row {
        chat: chat.to_owned(),
        sender: strip_device(sender),
        id: key.id.clone()?,
        ts: i64::try_from(m.message_timestamp?).ok()?,
        body,
        from_me,
        kind: kind.to_owned(),
        sender_name: m.push_name.clone().unwrap_or_default(),
    })
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
}
