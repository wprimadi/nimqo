//! Channels the account follows; posting to and creating one's own (see
//! `nimqo_whatsapp::channels`).

use std::sync::Arc;

use nimqo_whatsapp::channels;

use crate::chats::MessageKind;
use crate::{Core, CoreError};

#[derive(Debug, uniffi::Record)]
pub struct Channel {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub followers: u64,
    pub verified: bool,
    /// Owned or administered here: posting is allowed.
    pub admin: bool,
}

impl From<channels::Channel> for Channel {
    fn from(c: channels::Channel) -> Self {
        Self {
            id: c.id,
            name: c.name,
            description: c.description,
            followers: c.followers,
            verified: c.verified,
            admin: c.admin,
        }
    }
}

#[derive(Debug, uniffi::Record)]
pub struct ChannelReaction {
    pub emoji: String,
    pub count: u64,
}

#[derive(Debug, uniffi::Record)]
pub struct ChannelPost {
    /// Increasing; pass the oldest one shown to get the page before it.
    pub server_id: u64,
    pub timestamp_secs: i64,
    pub kind: MessageKind,
    pub body: Option<String>,
    pub edited: bool,
    /// A photo, video, audio, sticker or document to show: `picture`,
    /// `download_media` and `media_file` take the channel id and
    /// `server_id` as the seq. Files last only until the core stops.
    pub has_media: bool,
    /// Most first.
    pub reactions: Vec<ChannelReaction>,
}

#[uniffi::export]
impl Core {
    /// The channels this account follows. Asks the server; nothing is sent
    /// back or stored. Nil when offline.
    pub async fn channels(&self) -> Option<Vec<Channel>> {
        let client = Arc::clone(&self.client);
        match self
            .runtime
            .spawn(async move { channels::list(&client).await })
            .await
        {
            Ok(Ok(list)) => {
                log::info!("channels: {}", list.len());
                Some(list.into_iter().map(Channel::from).collect())
            }
            Ok(Err(e)) => {
                log::info!("channels not fetched: {e:#}");
                None
            }
            Err(e) => {
                log::warn!("channels task failed: {e}");
                None
            }
        }
    }

    /// A page of a channel's posts, oldest first, before `before` or the
    /// latest. Read-only, like `channels`. Nil when offline.
    pub async fn channel_posts(
        &self,
        channel_id: String,
        before: Option<u64>,
    ) -> Option<Vec<ChannelPost>> {
        let client = Arc::clone(&self.client);
        let channel = channel_id.clone();
        let fetched = self
            .runtime
            .spawn(async move { channels::posts(&client, &channel, before).await })
            .await;
        match fetched {
            Ok(Ok(posts)) => {
                log::info!("channel posts: {}", posts.len());
                Some(
                    posts
                        .into_iter()
                        .map(|p| {
                            let has_media = p.media.is_some();
                            if let Some(media) = p.media {
                                let seq = i64::try_from(p.server_id).unwrap_or(i64::MAX);
                                self.attachments.remember_channel_post(
                                    &channel_id,
                                    seq,
                                    p.kind,
                                    media,
                                );
                            }
                            ChannelPost {
                                server_id: p.server_id,
                                timestamp_secs: p.timestamp_secs,
                                kind: MessageKind::parse(p.kind),
                                body: p.body,
                                edited: p.edited,
                                has_media,
                                reactions: p
                                    .reactions
                                    .into_iter()
                                    .map(|(emoji, count)| ChannelReaction { emoji, count })
                                    .collect(),
                            }
                        })
                        .collect(),
                )
            }
            Ok(Err(e)) => {
                log::info!("channel posts not fetched: {e:#}");
                None
            }
            Err(e) => {
                log::warn!("channel posts task failed: {e}");
                None
            }
        }
    }

    /// Posts `text` to a channel this account runs.
    ///
    /// # Errors
    /// `SendRefused` for an empty post, or when the server refuses it.
    pub async fn post_to_channel(&self, channel_id: String, text: String) -> Result<(), CoreError> {
        let client = Arc::clone(&self.client);
        let sent = self
            .runtime
            .spawn(async move { channels::post_text(&client, &channel_id, &text).await })
            .await;
        match sent {
            Ok(Ok(())) => Ok(()),
            Ok(Err(e)) => Err(CoreError::SendRefused {
                reason: format!("Not posted: {e}"),
            }),
            Err(e) => Err(CoreError::SendRefused {
                reason: format!("Not posted: {e}"),
            }),
        }
    }

    /// Creates a channel owned by this account.
    ///
    /// # Errors
    /// `SendRefused` without a name, or when the server refuses.
    pub async fn create_channel(
        &self,
        name: String,
        description: Option<String>,
    ) -> Result<Channel, CoreError> {
        let client = Arc::clone(&self.client);
        let made = self
            .runtime
            .spawn(async move { channels::create(&client, &name, description.as_deref()).await })
            .await;
        match made {
            Ok(Ok(c)) => Ok(c.into()),
            Ok(Err(e)) => Err(CoreError::SendRefused {
                reason: format!("Not created: {e}"),
            }),
            Err(e) => Err(CoreError::SendRefused {
                reason: format!("Not created: {e}"),
            }),
        }
    }
}
