//! Channels the account follows and their posts, asked of the server when
//! the user opens them. Nothing goes back (no views, reactions or follows)
//! except what the user posts to a channel they run, or a channel they
//! create; nothing is stored, except opened media until the core stops
//! (`Attachments::clear_channel_files`).

use anyhow::{Result, anyhow};
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore_binary::JidExt as _;
use whatsapp_rust::{
    Client, Jid, NewsletterMetadata, NewsletterRole, NewsletterState, NewsletterVerification,
};

use crate::inbox::{classify, media_of};

/// Posts asked for at a time.
pub const PAGE: u32 = 30;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub followers: u64,
    pub verified: bool,
    /// The account owns or administers it, so may post.
    pub admin: bool,
}

impl From<NewsletterMetadata> for Channel {
    fn from(c: NewsletterMetadata) -> Self {
        Self {
            id: c.jid.to_string(),
            name: c.name,
            description: c.description.filter(|d| !d.trim().is_empty()),
            followers: c.subscriber_count,
            verified: c.verification == NewsletterVerification::Verified,
            admin: matches!(c.role, Some(NewsletterRole::Owner | NewsletterRole::Admin)),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Post {
    /// Server-assigned and increasing: the cursor for older pages.
    pub server_id: u64,
    pub timestamp_secs: i64,
    /// As `classify` names it; "deleted" for a revoked post.
    pub kind: &'static str,
    pub body: Option<String>,
    pub edited: bool,
    /// The encoded media message (`media_of`), for its picture and file.
    pub media: Option<Vec<u8>>,
    /// Each emoji and how many reacted with it, most first.
    pub reactions: Vec<(String, u64)>,
}

/// The followed channels that still exist, by name.
///
/// # Errors
/// The server query fails.
pub async fn list(client: &Client) -> Result<Vec<Channel>> {
    let mut channels: Vec<Channel> = client
        .newsletter()
        .list_subscribed()
        .await?
        .into_iter()
        .filter(|c| c.state == NewsletterState::Active)
        .map(Channel::from)
        .collect();
    channels.sort_by_cached_key(|c| c.name.to_lowercase());
    Ok(channels)
}

/// A page of posts, oldest first, from before `before` (a `server_id`) or
/// the latest.
///
/// # Errors
/// Not a channel id, or the server query fails.
pub async fn posts(client: &Client, channel: &str, before: Option<u64>) -> Result<Vec<Post>> {
    let jid = channel_jid(channel)?;
    let mut posts: Vec<Post> = client
        .newsletter()
        .get_messages(jid, PAGE, before)
        .await?
        .into_iter()
        .map(|m| {
            let (kind, body) = match &m.message {
                None => ("deleted", None),
                Some(message) => classify(message).unwrap_or(("unsupported", None)),
            };
            Post {
                server_id: m.server_id,
                timestamp_secs: i64::try_from(m.timestamp).unwrap_or(i64::MAX),
                kind,
                body,
                edited: m.message.is_some() && m.last_edit_timestamp_ms.is_some(),
                media: m.message.as_ref().and_then(media_of),
                reactions: {
                    let mut r: Vec<(String, u64)> = m
                        .reactions
                        .iter()
                        .filter(|r| r.count > 0)
                        .map(|r| (r.code.clone(), r.count))
                        .collect();
                    r.sort_by_key(|a| std::cmp::Reverse(a.1));
                    r
                },
            }
        })
        .collect();
    posts.sort_unstable_by_key(|p| p.server_id);
    Ok(posts)
}

fn channel_jid(channel: &str) -> Result<Jid> {
    let jid: Jid = channel.parse().map_err(|_| anyhow!("not a channel id"))?;
    if !jid.is_newsletter() {
        return Err(anyhow!("not a channel"));
    }
    Ok(jid)
}

/// Posts `text` to a channel the account runs. The server refuses anyone
/// else.
///
/// # Errors
/// Empty text, not a channel id, or the send fails.
pub async fn post_text(client: &Client, channel: &str, text: &str) -> Result<()> {
    let text = text.trim();
    if text.is_empty() {
        return Err(anyhow!("The post is empty."));
    }
    let jid = channel_jid(channel)?;
    let mut message = wa::Message::default();
    message.conversation = Some(text.to_owned());
    client.send_message(jid, message).await?;
    Ok(())
}

/// Creates a channel the account owns.
///
/// # Errors
/// An empty name, or the server refuses.
pub async fn create(client: &Client, name: &str, description: Option<&str>) -> Result<Channel> {
    let name = name.trim();
    if name.is_empty() {
        return Err(anyhow!("A channel needs a name."));
    }
    let description = description.map(str::trim).filter(|d| !d.is_empty());
    Ok(client.newsletter().create(name, description).await?.into())
}
