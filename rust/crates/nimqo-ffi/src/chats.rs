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
    /// Deleted for everyone by its sender.
    Deleted,
    Unsupported,
}

impl MessageKind {
    fn parse(kind: &str) -> Self {
        match kind {
            "text" => Self::Text,
            "image" => Self::Image,
            "video" => Self::Video,
            "audio" => Self::Audio,
            "document" => Self::Document,
            "sticker" => Self::Sticker,
            "deleted" => Self::Deleted,
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
            id: r.chat,
        }
    }
}

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
    pub from_me: bool,
    pub timestamp_secs: i64,
    pub kind: MessageKind,
    /// Text, or a media caption or file name.
    pub body: Option<String>,
    pub delivery: Delivery,
    /// What this message replies to.
    pub reply: Option<Reply>,
}

/// The quoted message of a reply, as quoted.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Reply {
    pub kind: MessageKind,
    pub body: Option<String>,
    /// None when the quoted message is not stored here.
    pub from_me: Option<bool>,
    pub sender_name: Option<String>,
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
            }),
        }
    }
}

/// A message found by local search.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct SearchHit {
    pub chat_id: String,
    pub seq: i64,
    pub timestamp_secs: i64,
    pub body: String,
    pub from_me: bool,
}
