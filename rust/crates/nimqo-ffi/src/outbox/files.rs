//! Photos, videos, audio, and documents. Queued like text (the test chat only, same queue
//! cap): the file is kept encrypted until sent, then uploaded and sent with
//! the id chosen when it was queued.

use nimqo_whatsapp::outbox::Pending;
use whatsapp_rust::UploadOptions;
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::media::{
    AudioOptions, DocumentOptions, ImageOptions, VideoOptions, audio_message, document_message,
    image_message, video_message,
};
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore::download::MediaType;

use super::{MAX_CHARS, Sender};
use crate::CoreError;

/// What WhatsApp itself accepts for photos.
const MAX_PHOTO_BYTES: usize = 16 * 1024 * 1024;
/// Kept in memory while sending; WhatsApp allows more.
const MAX_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;

/// How a file is sent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum FileKind {
    /// JPEG.
    Photo,
    /// MP4.
    Video,
    /// Plays in the chat; not a voice note.
    Audio,
    Document,
}

/// A file to send, prepared by the app: photos re-encoded as JPEG (which
/// also drops location and other metadata) with a small thumbnail; videos
/// as MP4 with a still as thumbnail.
#[derive(uniffi::Record)]
pub struct OutgoingFile {
    pub bytes: Vec<u8>,
    pub file_name: String,
    pub mimetype: String,
    pub caption: Option<String>,
    pub thumbnail: Option<Vec<u8>>,
    pub kind: FileKind,
    /// Length of a video or audio.
    pub duration_secs: Option<u32>,
}

pub(super) fn check_file(file: &OutgoingFile) -> Result<(), &'static str> {
    if file.bytes.is_empty() {
        return Err("The file is empty.");
    }
    let (limit, too_big) = match file.kind {
        FileKind::Photo | FileKind::Audio => {
            (MAX_PHOTO_BYTES, "Photos and audio can be at most 16 MB.")
        }
        FileKind::Video | FileKind::Document => (MAX_DOCUMENT_BYTES, "Files can be at most 64 MB."),
    };
    if file.bytes.len() > limit {
        return Err(too_big);
    }
    match file.kind {
        FileKind::Photo if file.mimetype != "image/jpeg" => return Err("Photos are sent as JPEG."),
        FileKind::Video if file.mimetype != "video/mp4" => return Err("Videos are sent as MP4."),
        FileKind::Audio if !file.mimetype.starts_with("audio/") => {
            return Err("Not an audio file.");
        }
        // WhatsApp shows no caption on audio; refused so the text is kept.
        FileKind::Audio
            if file
                .caption
                .as_deref()
                .is_some_and(|c| !c.trim().is_empty()) =>
        {
            return Err("Audio cannot have a caption. Send the text on its own.");
        }
        _ => {}
    }
    if file
        .caption
        .as_deref()
        .is_some_and(|c| c.chars().count() > MAX_CHARS)
    {
        return Err("The caption is too long.");
    }
    Ok(())
}

pub(super) fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        detail: format!("{e:#}"),
    }
}

impl Sender {
    /// Validates the file, keeps it encrypted, and queues it. The caller
    /// then flushes.
    pub fn enqueue_file(&self, chat_id: &str, file: &OutgoingFile) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        Self::may_send(chat_id)?;
        check_file(file).map_err(refused)?;
        let caption = file
            .caption
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty());
        let (kind, body, draft) = match file.kind {
            FileKind::Photo => {
                let mut d = wa::message::ImageMessage::default();
                d.mimetype = Some(file.mimetype.clone());
                d.caption = caption.map(str::to_owned);
                d.jpeg_thumbnail.clone_from(&file.thumbnail);
                ("image", caption, d.encode_to_vec())
            }
            FileKind::Video => {
                let mut d = wa::message::VideoMessage::default();
                d.mimetype = Some(file.mimetype.clone());
                d.caption = caption.map(str::to_owned);
                d.jpeg_thumbnail.clone_from(&file.thumbnail);
                d.seconds = file.duration_secs;
                ("video", caption, d.encode_to_vec())
            }
            FileKind::Audio => {
                let mut d = wa::message::AudioMessage::default();
                d.mimetype = Some(file.mimetype.clone());
                d.seconds = file.duration_secs;
                ("audio", None, d.encode_to_vec())
            }
            FileKind::Document => {
                let mut d = wa::message::DocumentMessage::default();
                d.mimetype = Some(file.mimetype.clone());
                d.file_name = Some(file.file_name.clone());
                d.caption = caption.map(str::to_owned);
                ("document", Some(file.file_name.as_str()), d.encode_to_vec())
            }
        };
        let id = self.client.generate_message_id();
        self.attachments
            .store_outgoing(chat_id, id.as_str(), &file.bytes)
            .map_err(storage)?;
        self.inbox
            .enqueue_file(chat_id, id.as_str(), crate::unix_now(), kind, body, &draft)
            .map_err(storage)?;
        self.listener.on_chats_changed(vec![chat_id.to_owned()]);
        Ok(())
    }

    /// Uploads a queued file and builds the message to send.
    pub(super) async fn file_message(&self, p: &Pending) -> Result<wa::Message, String> {
        let draft = p.media.as_deref().ok_or("no draft")?;
        let bytes = self
            .attachments
            .outgoing(&p.chat, &p.id)
            .map_err(|e| format!("file unreadable: {e:#}"))?;
        let upload = |media_type| async move {
            self.client
                .upload(bytes.to_vec(), media_type, UploadOptions::new())
                .await
                // The error can carry the media server URL and its auth token.
                .map_err(|_| "upload failed".to_owned())
        };
        Ok(match p.kind.as_str() {
            "image" => {
                let d = wa::message::ImageMessage::decode_from_slice(draft)
                    .map_err(|e| e.to_string())?;
                let mut options =
                    ImageOptions::default().with_mimetype(d.mimetype.unwrap_or_default());
                if let Some(c) = d.caption {
                    options = options.with_caption(c);
                }
                if let Some(t) = d.jpeg_thumbnail {
                    options = options.with_jpeg_thumbnail(t);
                }
                image_message(upload(MediaType::Image).await?, options)
            }
            "video" => {
                let d = wa::message::VideoMessage::decode_from_slice(draft)
                    .map_err(|e| e.to_string())?;
                let mut options =
                    VideoOptions::default().with_mimetype(d.mimetype.unwrap_or_default());
                if let Some(c) = d.caption {
                    options = options.with_caption(c);
                }
                if let Some(t) = d.jpeg_thumbnail {
                    options = options.with_jpeg_thumbnail(t);
                }
                if let Some(s) = d.seconds {
                    options = options.with_duration_seconds(s);
                }
                video_message(upload(MediaType::Video).await?, options)
            }
            "audio" => {
                let d = wa::message::AudioMessage::decode_from_slice(draft)
                    .map_err(|e| e.to_string())?;
                let mut options = AudioOptions::default()
                    .with_mimetype(d.mimetype.unwrap_or_default())
                    .with_ptt(false);
                if let Some(s) = d.seconds {
                    options = options.with_duration_seconds(s);
                }
                audio_message(upload(MediaType::Audio).await?, options)
            }
            "document" => {
                let d = wa::message::DocumentMessage::decode_from_slice(draft)
                    .map_err(|e| e.to_string())?;
                let name = d.file_name.unwrap_or_default();
                let mut options = DocumentOptions::default()
                    .with_mimetype(d.mimetype.unwrap_or_default())
                    .with_title(name.clone())
                    .with_file_name(name);
                if let Some(c) = d.caption {
                    options = options.with_caption(c);
                }
                document_message(upload(MediaType::Document).await?, options)
            }
            other => return Err(format!("cannot send {other} messages")),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(as_photo: bool, len: usize, mimetype: &str) -> OutgoingFile {
        let kind = if as_photo {
            FileKind::Photo
        } else {
            FileKind::Document
        };
        of(kind, len, mimetype)
    }

    fn of(kind: FileKind, len: usize, mimetype: &str) -> OutgoingFile {
        OutgoingFile {
            bytes: vec![0; len],
            file_name: "a".into(),
            mimetype: mimetype.into(),
            caption: None,
            thumbnail: None,
            kind,
            duration_secs: None,
        }
    }

    #[test]
    fn videos_are_mp4_and_audio_has_no_caption() {
        assert!(check_file(&of(FileKind::Video, 10, "video/mp4")).is_ok());
        assert!(check_file(&of(FileKind::Video, 10, "video/quicktime")).is_err());
        assert!(check_file(&of(FileKind::Audio, 10, "audio/mpeg")).is_ok());
        assert!(check_file(&of(FileKind::Audio, MAX_PHOTO_BYTES + 1, "audio/mpeg")).is_err());
        let mut captioned = of(FileKind::Audio, 10, "audio/mpeg");
        captioned.caption = Some("hi".into());
        assert!(check_file(&captioned).is_err());
    }

    #[test]
    fn files_stay_within_limits() {
        assert!(check_file(&file(true, 10, "image/jpeg")).is_ok());
        assert!(check_file(&file(false, 10, "application/pdf")).is_ok());
        assert!(check_file(&file(true, 0, "image/jpeg")).is_err());
        assert!(check_file(&file(true, MAX_PHOTO_BYTES + 1, "image/jpeg")).is_err());
        assert!(check_file(&file(true, 10, "image/png")).is_err());
    }
}
