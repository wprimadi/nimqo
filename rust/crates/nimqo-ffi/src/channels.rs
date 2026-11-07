//! Channels the account follows, read-only (see `nimqo_whatsapp::channels`).

use std::sync::Arc;

use nimqo_whatsapp::channels;

use crate::Core;
use crate::chats::MessageKind;

#[derive(Debug, uniffi::Record)]
pub struct Channel {
    pub id: String,
    pub name: String,
    pub description: Option<String>,
    pub followers: u64,
    pub verified: bool,
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
                Some(
                    list.into_iter()
                        .map(|c| Channel {
                            id: c.id,
                            name: c.name,
                            description: c.description,
                            followers: c.followers,
                            verified: c.verified,
                        })
                        .collect(),
                )
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
}
