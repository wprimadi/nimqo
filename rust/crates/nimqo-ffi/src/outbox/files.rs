//! Photos and documents. Queued like text (the test chat only, same queue
//! cap): the file is kept encrypted until sent, then uploaded and sent with
//! the id chosen when it was queued.

use nimqo_whatsapp::outbox::Pending;
use whatsapp_rust::UploadOptions;
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::media::{DocumentOptions, ImageOptions, document_message, image_message};
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore::download::MediaType;

use super::{MAX_CHARS, MAX_QUEUED, Sender};
use crate::CoreError;

/// What WhatsApp itself accepts for photos.
const MAX_PHOTO_BYTES: usize = 16 * 1024 * 1024;
/// Kept in memory while sending; WhatsApp allows more.
const MAX_DOCUMENT_BYTES: usize = 64 * 1024 * 1024;

/// A file to send, prepared by the app: photos re-encoded as JPEG (which
/// also drops location and other metadata) with a small thumbnail.
#[derive(uniffi::Record)]
pub struct OutgoingFile {
    pub bytes: Vec<u8>,
    pub file_name: String,
    pub mimetype: String,
    pub caption: Option<String>,
    pub thumbnail: Option<Vec<u8>>,
    /// Sent as a photo; otherwise as a document.
    pub as_photo: bool,
}

fn check_file(
    chat_id: &str,
    peer_chat: &str,
    file: &OutgoingFile,
    queued: usize,
) -> Result<(), &'static str> {
    if chat_id != peer_chat {
        return Err("During development NIMQO only sends to the test number.");
    }
    if file.bytes.is_empty() {
        return Err("The file is empty.");
    }
    let limit = if file.as_photo {
        MAX_PHOTO_BYTES
    } else {
        MAX_DOCUMENT_BYTES
    };
    if file.bytes.len() > limit {
        return Err(if file.as_photo {
            "Photos can be at most 16 MB."
        } else {
            "Files can be at most 64 MB."
        });
    }
    if file.as_photo && file.mimetype != "image/jpeg" {
        return Err("Photos are sent as JPEG.");
    }
    if file
        .caption
        .as_deref()
        .is_some_and(|c| c.chars().count() > MAX_CHARS)
    {
        return Err("The caption is longer than 1000 characters.");
    }
    if queued >= MAX_QUEUED {
        return Err("Too many messages waiting to send. Try again when they have gone out.");
    }
    Ok(())
}

fn storage(e: impl std::fmt::Display) -> CoreError {
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
        let _queueing = self
            .queueing
            .lock()
            .map_err(|_| refused("internal lock poisoned"))?;
        let queued = self.inbox.pending().map_err(storage)?.len();
        check_file(chat_id, &self.peer_chat(), file, queued).map_err(refused)?;
        let caption = file
            .caption
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty());
        let (kind, body, draft) = if file.as_photo {
            let mut d = wa::message::ImageMessage::default();
            d.mimetype = Some(file.mimetype.clone());
            d.caption = caption.map(str::to_owned);
            d.jpeg_thumbnail.clone_from(&file.thumbnail);
            ("image", caption, d.encode_to_vec())
        } else {
            let mut d = wa::message::DocumentMessage::default();
            d.mimetype = Some(file.mimetype.clone());
            d.file_name = Some(file.file_name.clone());
            d.caption = caption.map(str::to_owned);
            ("document", Some(file.file_name.as_str()), d.encode_to_vec())
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
                .map_err(|e| format!("upload failed: {e:#}"))
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
        OutgoingFile {
            bytes: vec![0; len],
            file_name: "a".into(),
            mimetype: mimetype.into(),
            caption: None,
            thumbnail: None,
            as_photo,
        }
    }

    #[test]
    fn files_go_to_the_test_chat_only_and_within_limits() {
        let peer = "62811@s.whatsapp.net";
        assert!(check_file(peer, peer, &file(true, 10, "image/jpeg"), 0).is_ok());
        assert!(check_file(peer, peer, &file(false, 10, "application/pdf"), 0).is_ok());
        assert!(
            check_file(
                "other@s.whatsapp.net",
                peer,
                &file(true, 10, "image/jpeg"),
                0
            )
            .is_err()
        );
        assert!(check_file(peer, peer, &file(true, 0, "image/jpeg"), 0).is_err());
        assert!(
            check_file(
                peer,
                peer,
                &file(true, MAX_PHOTO_BYTES + 1, "image/jpeg"),
                0
            )
            .is_err()
        );
        assert!(check_file(peer, peer, &file(true, 10, "image/png"), 0).is_err());
        assert!(check_file(peer, peer, &file(false, 10, "x"), MAX_QUEUED).is_err());
    }
}
