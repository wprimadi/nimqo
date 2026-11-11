//! Link previews: the title, description and picture a sender attaches to
//! a link in a text. Nothing is fetched to show one. A preview is kept only
//! when its link is in the text itself, so it can't stand for another site.

use diesel::sql_types::{BigInt, Binary, Text};
use diesel::{OptionalExtension, RunQueryDsl};
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::prelude::{MessageExt as _, wa};

use crate::inbox::Inbox;

/// Limits on what is kept and sent.
pub const MAX_TITLE: usize = 256;
pub const MAX_DESCRIPTION: usize = 1024;
pub const MAX_THUMBNAIL: usize = 96 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Link {
    /// As it is written in the text.
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    /// JPEG.
    pub thumbnail: Option<Vec<u8>>,
}

fn clip(s: Option<&str>, max: usize) -> Option<String> {
    let s = s?.trim();
    (!s.is_empty()).then(|| s.chars().take(max).collect())
}

impl Link {
    /// A preview for `text`, when its link is in it and it shows something.
    #[must_use]
    pub fn checked(self, text: &str) -> Option<Self> {
        let url = self.url.trim().to_owned();
        // Web links only, written out or bare ("example.com/a"); no other scheme.
        let web = url.starts_with("https://") || url.starts_with("http://") || !url.contains(':');
        if url.is_empty() || !web || !text.contains(&url) {
            return None;
        }
        let link = Self {
            url,
            title: clip(self.title.as_deref(), MAX_TITLE),
            description: clip(self.description.as_deref(), MAX_DESCRIPTION),
            thumbnail: self
                .thumbnail
                .filter(|t| !t.is_empty() && t.len() <= MAX_THUMBNAIL),
        };
        (link.title.is_some() || link.thumbnail.is_some()).then_some(link)
    }

    fn encode(&self) -> Vec<u8> {
        let mut m = wa::message::ExtendedTextMessage::default();
        m.matched_text = Some(self.url.clone());
        m.title.clone_from(&self.title);
        m.description.clone_from(&self.description);
        m.jpeg_thumbnail.clone_from(&self.thumbnail);
        m.encode_to_vec()
    }

    fn decode(bytes: &[u8]) -> Option<Self> {
        let m = wa::message::ExtendedTextMessage::decode_from_slice(bytes).ok()?;
        Some(Self {
            url: m.matched_text?,
            title: m.title,
            description: m.description,
            thumbnail: m.jpeg_thumbnail,
        })
    }

    /// Puts the preview on an outgoing text.
    pub fn attach(&self, message: &mut wa::Message) {
        let text = message.conversation.take();
        let ext = message.extended_text_message.get_or_insert_default();
        if ext.text.is_none() {
            ext.text = text;
        }
        ext.matched_text = Some(self.url.clone());
        ext.title.clone_from(&self.title);
        ext.description.clone_from(&self.description);
        ext.jpeg_thumbnail.clone_from(&self.thumbnail);
    }
}

/// The preview a received text carries, checked and ready to keep.
pub(crate) fn link_of(message: &wa::Message) -> Option<Vec<u8>> {
    let ext = message
        .get_base_message()
        .extended_text_message
        .as_option()?;
    let link = Link {
        url: ext.matched_text.clone()?,
        title: ext.title.clone(),
        description: ext.description.clone(),
        thumbnail: ext.jpeg_thumbnail.clone(),
    };
    Some(link.checked(ext.text.as_deref()?)?.encode())
}

impl Inbox {
    /// The preview of text message `seq`, if it has one.
    ///
    /// # Errors
    /// The store cannot be read.
    pub fn link(&self, chat: &str, seq: i64) -> anyhow::Result<Option<Link>> {
        #[derive(diesel::QueryableByName)]
        struct Row {
            #[diesel(sql_type = Binary)]
            media: Vec<u8>,
            #[diesel(sql_type = Text)]
            body: String,
        }
        let mut conn = self.lock()?;
        let row: Option<Row> = diesel::sql_query(
            "SELECT media, coalesce(body, '') AS body FROM messages
             WHERE rowid = ? AND chat = ? AND kind = 'text' AND media IS NOT NULL",
        )
        .bind::<BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .get_result(&mut *conn)
        .optional()?;
        // Checked again against the text as it is now.
        Ok(row.and_then(|r| Link::decode(&r.media)?.checked(&r.body)))
    }

    /// Keeps the preview of a text being sent from here (pending, own).
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_pending_link(&self, id: &str, link: &Link) -> anyhow::Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "UPDATE messages SET media = ? WHERE sender = ? AND id = ? AND kind = 'text' AND status = 'pending'",
        )
        .bind::<Binary, _>(link.encode())
        .bind::<Text, _>(crate::inbox::ME)
        .bind::<Text, _>(id)
        .execute(&mut *conn)?;
        Ok(())
    }
}

/// A pending text's kept preview, to send with it.
#[must_use]
pub fn pending_link(media: Option<&[u8]>) -> Option<Link> {
    Link::decode(media?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn link(url: &str) -> Link {
        Link {
            url: url.into(),
            title: Some(" Title ".into()),
            description: None,
            thumbnail: None,
        }
    }

    #[test]
    fn a_preview_must_name_a_web_link_in_the_text() {
        let text = "see https://example.com/a now";
        let kept = link("https://example.com/a").checked(text).unwrap();
        assert_eq!(kept.title.as_deref(), Some("Title"));
        // Not in the text: it would stand for a site the text does not name.
        assert_eq!(link("https://other.example").checked(text), None);
        assert_eq!(
            link("javascript:alert(1)").checked("javascript:alert(1)"),
            None
        );
        // Nothing to show.
        let bare = Link {
            title: None,
            ..link("https://example.com/a")
        };
        assert_eq!(bare.checked(text), None);
    }

    #[test]
    fn an_outgoing_text_carries_its_preview() {
        let mut m = wa::Message::default();
        m.conversation = Some("go https://example.com".into());
        link("https://example.com").attach(&mut m);
        let ext = m.extended_text_message.as_option().unwrap();
        assert_eq!(ext.text.as_deref(), Some("go https://example.com"));
        assert_eq!(ext.title.as_deref(), Some(" Title "));
        assert_eq!(m.conversation, None);
        assert!(link_of(&m).is_some());
    }
}
