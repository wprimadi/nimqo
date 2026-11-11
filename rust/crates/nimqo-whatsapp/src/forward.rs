//! Forwarding: a copy of a stored message sent on, marked forwarded. Media
//! goes by the original upload (its keys and path), as WhatsApp does.

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Binary, Nullable, Text};
use whatsapp_rust::buffa::{Message as _, MessageField};
use whatsapp_rust::prelude::{MessageBuilderExt as _, wa};

use crate::inbox::{Inbox, ME};
use crate::replies::Quoted;

/// Kinds that can be forwarded: the rest have no stored copy to send.
pub const FORWARDABLE: [&str; 6] = ["text", "image", "video", "audio", "document", "sticker"];

impl Inbox {
    /// Stores a forwarded copy of `original` as pending in `chat`.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue_forward(&self, chat: &str, id: &str, ts: i64, original: &Quoted) -> Result<()> {
        self.enqueue_copy(chat, id, ts, original, true)
    }

    /// Stores a copy of `original` as pending in `chat`; `forwarded` marks
    /// it so (a sticker picked again is not).
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue_copy(
        &self,
        chat: &str,
        id: &str,
        ts: i64,
        original: &Quoted,
        forwarded: bool,
    ) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "INSERT INTO messages (chat, sender, id, ts, body, from_me, kind, status, media,
               forwarded, expires_at)
             VALUES (?, ?, ?, ?, ?, 1, ?, 'pending', ?, ?,
               ? + (SELECT NULLIF(seconds, 0) FROM chat_timers WHERE chat = ?))",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .bind::<BigInt, _>(ts)
        .bind::<Nullable<Text>, _>(original.body.as_deref())
        .bind::<Text, _>(&original.kind)
        .bind::<Nullable<Binary>, _>(original.media.as_deref())
        .bind::<diesel::sql_types::Bool, _>(forwarded)
        .bind::<BigInt, _>(ts)
        .bind::<Text, _>(chat)
        .execute(&mut *conn)?;
        Ok(())
    }
}

/// The newest stickers seen in any chat, each once, as (chat, seq): those
/// that can be sent again by their upload. Animated (Lottie) ones are left
/// out, as they come wrapped and are not sent here.
///
/// # Errors
/// The query fails.
pub fn recent_stickers(inbox: &Inbox, limit: usize) -> Result<Vec<(String, i64)>> {
    #[derive(diesel::QueryableByName)]
    struct Row {
        #[diesel(sql_type = Text)]
        chat: String,
        #[diesel(sql_type = BigInt)]
        seq: i64,
        #[diesel(sql_type = Binary)]
        media: Vec<u8>,
    }
    let rows: Vec<Row> = {
        let mut conn = inbox.lock()?;
        diesel::sql_query(
            "SELECT chat, rowid AS seq, media FROM messages
             WHERE kind = 'sticker' AND media IS NOT NULL AND chat <> 'status@broadcast'
             ORDER BY ts DESC, rowid DESC LIMIT 600",
        )
        .load(&mut *conn)?
    };
    let mut seen = std::collections::HashSet::new();
    Ok(rows
        .into_iter()
        .filter(|r| {
            let Ok(s) = wa::message::StickerMessage::decode_from_slice(&r.media) else {
                return false;
            };
            sendable(&s) && seen.insert(s.file_sha256.unwrap_or_default())
        })
        .take(limit)
        .map(|r| (r.chat, r.seq))
        .collect())
}

/// Uploaded (path and key known) and not animated.
fn sendable(s: &wa::message::StickerMessage) -> bool {
    s.direct_path.as_deref().is_some_and(|p| !p.is_empty())
        && s.media_key.as_deref().is_some_and(|k| !k.is_empty())
        && s.file_sha256.as_deref().is_some_and(|h| !h.is_empty())
        && s.mimetype.as_deref() != Some("application/was")
}

/// A sticker sent again as picked, not forwarded: its upload, without the
/// context it first came with.
#[must_use]
pub fn sticker(media: &[u8]) -> Option<wa::Message> {
    let mut x = wa::message::StickerMessage::decode_from_slice(media).ok()?;
    if !sendable(&x) {
        return None;
    }
    x.context_info = MessageField::none();
    let mut m = wa::Message::default();
    m.sticker_message = MessageField::some(x);
    Some(m)
}

/// The message sent for a forwarded copy; None when it cannot be rebuilt.
#[must_use]
pub fn forwarded(kind: &str, body: Option<&str>, media: Option<&[u8]>) -> Option<wa::Message> {
    let mut context = wa::ContextInfo::default();
    context.is_forwarded = Some(true);
    context.forwarding_score = Some(1);
    if kind == "text" {
        return Some(wa::Message::text_with_context(body?.to_owned(), context));
    }
    let context = MessageField::some(context);
    let media = media?;
    let mut m = wa::Message::default();
    match kind {
        "image" => {
            let mut x = wa::message::ImageMessage::decode_from_slice(media).ok()?;
            x.context_info = context;
            m.image_message = MessageField::some(x);
        }
        "video" => {
            let mut x = wa::message::VideoMessage::decode_from_slice(media).ok()?;
            x.context_info = context;
            m.video_message = MessageField::some(x);
        }
        "audio" => {
            let mut x = wa::message::AudioMessage::decode_from_slice(media).ok()?;
            x.context_info = context;
            m.audio_message = MessageField::some(x);
        }
        "document" => {
            let mut x = wa::message::DocumentMessage::decode_from_slice(media).ok()?;
            x.context_info = context;
            m.document_message = MessageField::some(x);
        }
        "sticker" => {
            let mut x = wa::message::StickerMessage::decode_from_slice(media).ok()?;
            x.context_info = context;
            m.sticker_message = MessageField::some(x);
        }
        _ => return None,
    }
    Some(m)
}

#[cfg(test)]
mod tests {
    use super::*;
    use whatsapp_rust::prelude::MessageExt as _;

    #[test]
    fn copies_are_marked_forwarded_and_keep_their_media() {
        let text = forwarded("text", Some("hi"), None).unwrap();
        assert_eq!(text.text_content(), Some("hi"));
        assert!(crate::inbox::is_forwarded(&text));
        let mut image = wa::message::ImageMessage::default();
        image.caption = Some("look".into());
        let sent = forwarded("image", None, Some(&image.encode_to_vec())).unwrap();
        assert!(crate::inbox::is_forwarded(&sent));
        assert_eq!(
            sent.image_message.as_option().unwrap().caption.as_deref(),
            Some("look")
        );
        assert!(
            forwarded("image", None, None).is_none(),
            "no media, no copy"
        );
        assert!(forwarded("unsupported", Some("x"), None).is_none());
    }

    #[test]
    fn a_sticker_is_sent_again_only_by_its_upload() {
        let mut s = wa::message::StickerMessage::default();
        s.mimetype = Some("image/webp".into());
        assert!(sticker(&s.encode_to_vec()).is_none(), "never uploaded");
        s.direct_path = Some("/v/t62/x".into());
        s.media_key = Some(vec![1; 32]);
        s.file_sha256 = Some(vec![2; 32]);
        s.context_info = MessageField::some(wa::ContextInfo::default());
        let m = sticker(&s.encode_to_vec()).expect("sendable");
        let sent = m.sticker_message.as_option().unwrap();
        assert!(sent.context_info.as_option().is_none());
        assert!(!crate::inbox::is_forwarded(&m));
        s.mimetype = Some("application/was".into());
        assert!(sticker(&s.encode_to_vec()).is_none(), "animated");
    }
}
