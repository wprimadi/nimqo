//! History sync import (plan 10.4): the phone sends recent chats after
//! pairing and on demand. Messages go into the same store as live ones;
//! the (chat, id) key makes overlap with live delivery harmless.

use anyhow::Result;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::types::events::LazyHistorySync;

use crate::inbox::{Inbox, ME, Row, classify};

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
    let (mut total, mut chats, mut pairs) = (0, Vec::new(), Vec::new());
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
        let name = chat.ends_with("@g.us").then_some(conv.name).flatten();
        inbox.import(&chat, name, rows)?;
        if let Some(seconds) = conv.ephemeral_expiration {
            let timer = crate::effects::Effect::Timer {
                chat: chat.clone(),
                seconds,
            };
            inbox.commit(Vec::new(), &[timer])?;
        }
        chats.push(chat);
    }
    for m in stream.remainder()?.phone_number_to_lid_mappings {
        pairs.extend(lid_pair(m.lid_jid.as_deref(), m.pn_jid.as_deref()));
    }
    inbox.record_lids(&pairs)?;
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
        media: crate::inbox::media_of(m.message.as_option()?),
        // ponytail: history counts as read; the conversation's unread
        // count could mark its newest messages unread instead.
        read: true,
        expires_at: m
            .ephemeral_duration
            .filter(|d| *d > 0)
            .and_then(|d| Some(i64::try_from(m.message_timestamp?).ok()? + i64::from(d))),
    })
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
}
