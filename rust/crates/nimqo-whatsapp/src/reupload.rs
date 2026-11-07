//! Media the CDN no longer serves (old messages): the sender's phone is
//! asked to upload it again, and the message gets the new path.

use anyhow::{Result, anyhow};
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::{Client, Jid, MediaRetryResult, MediaReuploadRequest, MessageId, MessageRef};

/// Asks for message `id`'s media again; the media message (`media_of`)
/// with its new direct path, or `None` when the phone could not.
///
/// # Errors
/// Bad stored data, or the request fails (offline, or no answer in 30 s).
pub async fn ask(
    client: &Client,
    chat: &str,
    id: &str,
    from_me: bool,
    kind: &str,
    media: &[u8],
) -> Result<Option<Vec<u8>>> {
    let jid: Jid = chat.parse().map_err(|_| anyhow!("bad chat id"))?;
    let key = media_key(kind, media)?;
    let target = MessageRef::new(&jid, MessageId::new(id)?, None, from_me)?;
    let result = client
        .media_reupload()
        .request(&MediaReuploadRequest {
            target,
            media_key: &key,
        })
        .await?;
    log::info!("media re-upload: {}", outcome(&result));
    match result {
        MediaRetryResult::Success { direct_path } => Ok(Some(with_path(kind, media, direct_path)?)),
        _ => Ok(None),
    }
}

fn outcome(result: &MediaRetryResult) -> &'static str {
    match result {
        MediaRetryResult::Success { .. } => "uploaded again",
        MediaRetryResult::NotFound => "gone from the phone",
        MediaRetryResult::DecryptionError => "decryption error",
        MediaRetryResult::GeneralError => "refused",
    }
}

/// Runs `$body` with `$m` bound to the decoded media message of `$kind`.
macro_rules! with_media {
    ($kind:expr, $bytes:expr, |$m:ident| $body:expr) => {
        match $kind {
            "image" => {
                let mut $m = wa::message::ImageMessage::decode_from_slice($bytes)?;
                $body
            }
            "video" => {
                let mut $m = wa::message::VideoMessage::decode_from_slice($bytes)?;
                $body
            }
            "document" => {
                let mut $m = wa::message::DocumentMessage::decode_from_slice($bytes)?;
                $body
            }
            "sticker" => {
                let mut $m = wa::message::StickerMessage::decode_from_slice($bytes)?;
                $body
            }
            _ => {
                let mut $m = wa::message::AudioMessage::decode_from_slice($bytes)?;
                $body
            }
        }
    };
}

fn media_key(kind: &str, media: &[u8]) -> Result<[u8; 32]> {
    let key: Option<Vec<u8>> = with_media!(kind, media, |m| m.media_key.take());
    key.and_then(|k| <[u8; 32]>::try_from(k).ok())
        .ok_or_else(|| anyhow!("no media key"))
}

fn with_path(kind: &str, media: &[u8], path: String) -> Result<Vec<u8>> {
    Ok(with_media!(kind, media, |m| {
        m.direct_path = Some(path);
        m.encode_to_vec()
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_new_path_replaces_the_old_and_the_key_is_kept() {
        let mut video = wa::message::VideoMessage::default();
        video.media_key = Some(vec![3; 32]);
        video.direct_path = Some("/old".into());
        let bytes = video.encode_to_vec();
        assert_eq!(media_key("video", &bytes).unwrap(), [3; 32]);
        let updated = with_path("video", &bytes, "/new".into()).unwrap();
        let updated = wa::message::VideoMessage::decode_from_slice(&updated).unwrap();
        assert_eq!(updated.direct_path.as_deref(), Some("/new"));
        assert_eq!(updated.media_key, Some(vec![3; 32]));
        assert!(
            media_key(
                "image",
                &wa::message::ImageMessage::default().encode_to_vec()
            )
            .is_err()
        );
    }
}
