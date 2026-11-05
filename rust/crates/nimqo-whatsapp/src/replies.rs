//! Replies. A reply carries a copy of what it quotes, so the quote shows
//! even when the original is not stored here; the original's sender is
//! looked up locally when it is.

use anyhow::Result;
use diesel::prelude::*;
use diesel::sql_types::{BigInt, Bool, Nullable, Text};
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::prelude::MessageExt as _;
use whatsapp_rust::prelude::wa;

use crate::inbox::Inbox;

/// What a message quotes: the original's id and a copy of its content.
pub(crate) struct Quote {
    pub id: String,
    pub kind: String,
    pub body: Option<String>,
}

pub(crate) fn quote_of(message: &wa::Message) -> Option<Quote> {
    let context = message.context_info()?;
    let id = context.stanza_id.clone().filter(|id| !id.is_empty())?;
    let (kind, body) = context
        .quoted_message
        .as_option()
        .and_then(crate::inbox::classify)
        .unwrap_or(("unsupported", None));
    Some(Quote {
        id,
        kind: kind.to_owned(),
        body,
    })
}

/// A stored message about to be quoted.
#[derive(QueryableByName)]
pub struct Quoted {
    #[diesel(sql_type = Text)]
    pub id: String,
    #[diesel(sql_type = Text)]
    pub sender: String,
    #[diesel(sql_type = Bool)]
    pub from_me: bool,
    #[diesel(sql_type = Text)]
    pub kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub body: Option<String>,
    #[diesel(sql_type = Nullable<diesel::sql_types::Binary>)]
    pub media: Option<Vec<u8>>,
}

impl Quoted {
    /// The copy of the original sent along with a reply.
    #[must_use]
    pub fn message(&self) -> wa::Message {
        let mut m = wa::Message::default();
        let media = self.media.as_deref();
        match self.kind.as_str() {
            "image" => {
                if let Some(image) =
                    media.and_then(|b| wa::message::ImageMessage::decode_from_slice(b).ok())
                {
                    m.image_message = whatsapp_rust::buffa::MessageField::some(image);
                    return m;
                }
            }
            "document" => {
                if let Some(doc) =
                    media.and_then(|b| wa::message::DocumentMessage::decode_from_slice(b).ok())
                {
                    m.document_message = whatsapp_rust::buffa::MessageField::some(doc);
                    return m;
                }
            }
            _ => {}
        }
        m.conversation = Some(self.body.clone().unwrap_or_default());
        m
    }
}

const QUOTED: &str = "SELECT id, sender, from_me, kind, body, media FROM messages
                      WHERE chat = ? AND kind <> 'deleted' AND ";

impl Inbox {
    /// Message `seq` of `chat`, to reply to.
    ///
    /// # Errors
    /// The query fails.
    pub fn quoted_by_seq(&self, chat: &str, seq: i64) -> Result<Option<Quoted>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(format!("{QUOTED} rowid = ?"))
            .bind::<Text, _>(chat)
            .bind::<BigInt, _>(seq)
            .get_result(&mut *conn)
            .optional()?)
    }

    /// The message an own reply quotes, by its id.
    ///
    /// # Errors
    /// The query fails.
    pub fn quoted_by_id(&self, chat: &str, id: &str) -> Result<Option<Quoted>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(format!("{QUOTED} id = ? LIMIT 1"))
            .bind::<Text, _>(chat)
            .bind::<Text, _>(id)
            .get_result(&mut *conn)
            .optional()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use whatsapp_rust::prelude::MessageBuilderExt as _;

    #[test]
    fn a_reply_keeps_its_quote() {
        let mut context = wa::ContextInfo::default();
        context.stanza_id = Some("orig".into());
        context.quoted_message =
            whatsapp_rust::buffa::MessageField::some(wa::Message::text("hello"));
        let reply = wa::Message::text_with_context("hi back", context);
        let q = quote_of(&reply).unwrap();
        assert_eq!(
            (q.id.as_str(), q.kind.as_str(), q.body.as_deref()),
            ("orig", "text", Some("hello"))
        );
        assert!(quote_of(&wa::Message::text("plain")).is_none());
    }
}

#[cfg(test)]
mod spoofing {
    use crate::inbox::{Fault, Inbox};
    use crate::vault::Key;

    #[test]
    fn a_stored_original_overrides_the_quoted_copy() {
        let path = std::env::temp_dir().join(format!("nimqo-replies-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([3; 32]), Fault::None).unwrap();
        let chat = "62811@s.whatsapp.net";
        inbox.enqueue(chat, "mine", 1, "the real text").unwrap();
        // A reply naming that message but carrying a forged copy.
        let forged = super::Quoted {
            id: "mine".into(),
            sender: chat.into(),
            from_me: false,
            kind: "text".into(),
            body: Some("forged".into()),
            media: None,
        };
        inbox
            .enqueue_reply(chat, "r1", 2, "reply", Some(&forged))
            .unwrap();
        let rows = inbox.messages(chat, 10).unwrap();
        let reply = rows.iter().find(|r| r.id == "r1").unwrap();
        assert_eq!(reply.quote_body.as_deref(), Some("the real text"));
        assert_eq!(reply.quote_from_me, Some(true));
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
