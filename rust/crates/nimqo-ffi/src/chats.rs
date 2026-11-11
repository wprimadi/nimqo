//! Read-only chat list and timeline records (plan 8: DTOs at the boundary).

use nimqo_whatsapp::inbox::{ChatRow, MessageRow};

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MessageKind {
    Text,
    Image,
    Video,
    Audio,
    Document,
    Sticker,
    /// Drawn from `Core::message_card`; the body is a one-line summary.
    Poll,
    Location,
    Contact,
    /// Text with buttons or a list: `Core::message_card`.
    Buttons,
    /// Deleted for everyone by its sender.
    Deleted,
    /// A call; the body is `<voice|video> <outcome> <seconds>`.
    Call,
    Unsupported,
}

impl MessageKind {
    pub(crate) fn parse(kind: &str) -> Self {
        match kind {
            // "choice": an answer to buttons, sent from here.
            "text" | "choice" => Self::Text,
            "image" => Self::Image,
            "video" => Self::Video,
            "audio" => Self::Audio,
            "document" => Self::Document,
            "sticker" => Self::Sticker,
            "poll" => Self::Poll,
            "location" => Self::Location,
            "contact" => Self::Contact,
            "buttons" => Self::Buttons,
            "deleted" => Self::Deleted,
            "call" => Self::Call,
            _ => Self::Unsupported,
        }
    }
}

/// Delivery state of own messages; `None` for received ones.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Delivery {
    None,
    Pending,
    Sent,
    Delivered,
    Read,
    Failed,
}

impl Delivery {
    fn parse(status: &str) -> Self {
        match status {
            "pending" => Self::Pending,
            "sent" => Self::Sent,
            "delivered" => Self::Delivered,
            "read" => Self::Read,
            "failed" => Self::Failed,
            _ => Self::None,
        }
    }
}

/// One row of the chat list: the chat and its latest message.
// Independent flags, as the app shows them.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Chat {
    pub id: String,
    pub is_group: bool,
    /// Push name of the other person, when one was seen.
    pub name: Option<String>,
    /// `+<digits>` for a phone-number chat.
    pub phone: Option<String>,
    pub last_activity_secs: i64,
    pub last_kind: MessageKind,
    pub last_body: Option<String>,
    pub last_from_me: bool,
    /// Received messages not read yet.
    pub unread: u32,
    /// Name saved in the phone's address book.
    pub contact_name: Option<String>,
    /// Disappearing-message timer in seconds; 0 when off.
    pub timer_secs: u32,
    /// No notification or Dock count for it.
    pub muted: bool,
    /// Pinned to the top of the list.
    pub pinned: bool,
    /// Kept out of the list, under Archived.
    pub archived: bool,
    /// Someone is typing or recording in it now.
    pub activity: Option<Activity>,
}

/// Typing or recording a voice message, now.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Activity {
    pub recording: bool,
    /// Who, in a group; nil in a person's chat.
    pub who: Option<String>,
}

impl From<ChatRow> for Chat {
    fn from(r: ChatRow) -> Self {
        let (user, server) = r.chat.split_once('@').unwrap_or((&r.chat, ""));
        Self {
            is_group: server == "g.us",
            phone: (server == "s.whatsapp.net").then(|| format!("+{user}")),
            name: r.name,
            last_activity_secs: r.ts,
            last_kind: MessageKind::parse(&r.kind),
            last_body: r.body,
            last_from_me: r.from_me,
            unread: u32::try_from(r.unread).unwrap_or(u32::MAX),
            contact_name: r.contact_name,
            timer_secs: u32::try_from(r.timer).unwrap_or(0),
            muted: r.muted,
            pinned: r.pinned > 0,
            archived: r.archived,
            activity: None,
            id: r.chat,
        }
    }
}

// Independent flags, as the app shows them.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct ChatMessage {
    pub id: String,
    /// Unique within the chat (ids are not, in groups); with
    /// `timestamp_secs` it is the cursor for older pages.
    pub seq: i64,
    pub sender: String,
    pub sender_name: Option<String>,
    /// The sender's name in the phone's address book.
    pub contact_name: Option<String>,
    pub edited: bool,
    /// A picture (thumbnail or full) can be shown for this message.
    pub has_media: bool,
    /// Every reaction's emoji, concatenated (e.g. "👍❤️").
    pub reactions: Option<String>,
    /// This account's own reaction, if any.
    pub my_reaction: Option<String>,
    pub from_me: bool,
    pub timestamp_secs: i64,
    pub kind: MessageKind,
    /// Text, or a media caption or file name.
    pub body: Option<String>,
    pub delivery: Delivery,
    /// What this message replies to.
    pub reply: Option<Reply>,
    /// Who each "@number" in `body` is, where known.
    pub mentions: Vec<Mention>,
    /// Marked forwarded by whoever sent it.
    pub forwarded: bool,
    pub starred: bool,
    /// Changes when a poll's votes do.
    pub revision: i64,
    /// A text with a link preview (`Core::link_preview`).
    pub has_link: bool,
    /// A video that plays as a GIF: looping, silent, without controls.
    pub gif: bool,
}

/// A link's title, description and picture, shown under a text.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct LinkPreview {
    /// As written in the text.
    pub url: String,
    pub title: Option<String>,
    pub description: Option<String>,
    pub thumbnail: Option<Vec<u8>>,
}

impl From<nimqo_whatsapp::links::Link> for LinkPreview {
    fn from(l: nimqo_whatsapp::links::Link) -> Self {
        Self {
            url: l.url,
            title: l.title,
            description: l.description,
            thumbnail: l.thumbnail,
        }
    }
}

impl From<LinkPreview> for nimqo_whatsapp::links::Link {
    fn from(l: LinkPreview) -> Self {
        Self {
            url: l.url,
            title: l.title,
            description: l.description,
            thumbnail: l.thumbnail,
        }
    }
}

/// Someone in the address book.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Contact {
    pub id: String,
    pub name: String,
}

/// "@`user`" in a message body stands for `name`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Mention {
    pub user: String,
    pub name: String,
}

/// The digits after each "@" in `body` that look like a WhatsApp user (a
/// phone number or a LID), each once.
/// `body` with each "@number" mention that `name` knows written "@Name".
pub(crate) fn named_mentions(body: &str, name: &mut impl FnMut(&str) -> Option<String>) -> String {
    let mut parts = body.split('@');
    let mut out = parts.next().unwrap_or_default().to_owned();
    for rest in parts {
        let end = rest
            .find(|c: char| !c.is_ascii_digit())
            .unwrap_or(rest.len());
        let (digits, tail) = rest.split_at(end);
        out.push('@');
        match name(digits).filter(|_| (5..=20).contains(&digits.len())) {
            Some(n) => out.push_str(&n),
            None => out.push_str(digits),
        }
        out.push_str(tail);
    }
    out
}

pub(crate) fn mentioned_users(body: &str) -> Vec<&str> {
    let mut users: Vec<&str> = body
        .split('@')
        .skip(1)
        .filter_map(|rest| {
            let end = rest
                .find(|c: char| !c.is_ascii_digit())
                .unwrap_or(rest.len());
            Some(&rest[..end]).filter(|d| (5..=20).contains(&d.len()))
        })
        .collect();
    users.sort_unstable();
    users.dedup();
    users
}

/// The quoted message of a reply, as quoted.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Reply {
    pub kind: MessageKind,
    pub body: Option<String>,
    /// None when the quoted message is not stored here.
    pub from_me: Option<bool>,
    pub sender_name: Option<String>,
    /// The quoted message's seq, to jump to it; None when not stored here.
    pub seq: Option<i64>,
}

impl From<MessageRow> for ChatMessage {
    fn from(r: MessageRow) -> Self {
        Self {
            id: r.id,
            seq: r.seq,
            has_media: r.has_media,
            sender: r.sender,
            sender_name: r.sender_name.filter(|n| !n.is_empty()),
            contact_name: r.contact_name,
            edited: r.edited,
            reactions: r.reactions,
            my_reaction: r.my_reaction,
            revision: r.revision,
            has_link: r.has_link,
            gif: false,
            from_me: r.from_me,
            timestamp_secs: r.ts,
            kind: MessageKind::parse(&r.kind),
            body: r.body,
            delivery: Delivery::parse(&r.status),
            reply: r.reply_to.map(|_| Reply {
                kind: MessageKind::parse(r.quote_kind.as_deref().unwrap_or_default()),
                body: r.quote_body,
                from_me: r.quote_from_me,
                sender_name: r.quote_name,
                seq: r.quote_seq,
            }),
            mentions: Vec::new(),
            forwarded: r.forwarded,
            starred: r.starred,
        }
    }
}

/// A message found by local search.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub chat_id: String,
    pub seq: i64,
    pub timestamp_secs: i64,
    pub kind: MessageKind,
    pub body: String,
    pub from_me: bool,
}

impl From<nimqo_whatsapp::search::Hit> for SearchHit {
    fn from(h: nimqo_whatsapp::search::Hit) -> Self {
        Self {
            chat_id: h.chat,
            seq: h.seq,
            timestamp_secs: h.ts,
            kind: MessageKind::parse(&h.kind),
            body: h.body.unwrap_or_default(),
            from_me: h.from_me,
        }
    }
}

#[cfg(test)]
mod mention_tests {
    use super::*;

    #[test]
    fn previews_name_mentions_they_know() {
        let mut name = |u: &str| (u == "628111").then(|| "Ana".to_owned());
        assert_eq!(
            named_mentions("hi @628111, @628222 and a@b @12", &mut name),
            "hi @Ana, @628222 and a@b @12"
        );
        assert_eq!(named_mentions("no mention", &mut name), "no mention");
    }

    #[test]
    fn mentions_are_long_digit_runs_after_at() {
        assert_eq!(
            super::mentioned_users("hi @178219684741240, @62811 and @62811 a@b @12"),
            vec!["178219684741240", "62811"]
        );
    }
}
