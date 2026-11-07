//! Channels the account follows and their posts, asked of the server when
//! the user opens them. Read-only: nothing goes back (no views, reactions or
//! follows) and nothing is stored.

use anyhow::{Result, anyhow};
use whatsapp_rust::{Client, Jid, NewsletterState, NewsletterVerification};

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
        .map(|c| Channel {
            id: c.jid.to_string(),
            name: c.name,
            description: c.description.filter(|d| !d.trim().is_empty()),
            followers: c.subscriber_count,
            verified: c.verification == NewsletterVerification::Verified,
        })
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
    let jid: Jid = channel.parse().map_err(|_| anyhow!("not a channel id"))?;
    if !channel.ends_with("@newsletter") {
        return Err(anyhow!("not a channel"));
    }
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
            }
        })
        .collect();
    posts.sort_unstable_by_key(|p| p.server_id);
    Ok(posts)
}
