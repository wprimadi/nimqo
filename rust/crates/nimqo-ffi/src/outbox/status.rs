//! Posting own status updates. During development the update is encrypted
//! for the test number only (and the account's own devices): nobody else
//! can see it, whatever the phone's status privacy says.

use whatsapp_rust::media::{ImageOptions, image_message};
use whatsapp_rust::prelude::wa;
use whatsapp_rust::wacore::download::MediaType;
use whatsapp_rust::{MessageId, StatusPrivacySetting, StatusSendOptions, UploadOptions};

use super::Sender;
use super::files::{FileKind, OutgoingFile, check_file};
use crate::CoreError;

/// What the phone allows in a text status.
const MAX_STATUS_CHARS: usize = 700;
/// The phone's default text status colour (opaque teal).
const BACKGROUND: u32 = 0xFF1E_6E4F;

/// A text status, or a photo with an optional caption.
fn check_status(text: &str, photo: Option<&OutgoingFile>) -> Result<(), &'static str> {
    if text.chars().count() > MAX_STATUS_CHARS {
        return Err("A status can have at most 700 characters.");
    }
    match photo {
        Some(p) if p.kind != FileKind::Photo => Err("Only photos can be posted as a status here."),
        // Same chat on both sides: only the file's own checks apply.
        Some(p) => check_file("", "", p, 0),
        None if text.trim().is_empty() => Err("The status is empty."),
        None => Ok(()),
    }
}

impl Sender {
    /// Posts a status update seen only by the test number, and keeps it
    /// under My Status.
    pub async fn post_status(
        &self,
        text: &str,
        photo: Option<&OutgoingFile>,
    ) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        check_status(text, photo).map_err(refused)?;
        let text = text.trim();
        let caption = Some(text).filter(|t| !t.is_empty());
        let message = match photo {
            None => {
                let mut m = wa::message::ExtendedTextMessage::default();
                m.text = Some(text.to_owned());
                m.background_argb = Some(BACKGROUND);
                let mut message = wa::Message::default();
                message.extended_text_message = whatsapp_rust::buffa::MessageField::some(m);
                message
            }
            Some(p) => {
                let upload = self
                    .client
                    .upload(p.bytes.clone(), MediaType::Image, UploadOptions::new())
                    .await
                    // The error can carry the media server URL and its token.
                    .map_err(|_| refused("The photo could not be uploaded."))?;
                let mut options = ImageOptions::default().with_mimetype(p.mimetype.clone());
                if let Some(c) = caption {
                    options = options.with_caption(c.to_owned());
                }
                if let Some(t) = p.thumbnail.clone() {
                    options = options.with_jpeg_thumbnail(t);
                }
                image_message(upload, options)
            }
        };
        let id = self.client.generate_message_id();
        let options = StatusSendOptions::default()
            .with_privacy(StatusPrivacySetting::AllowList)
            .with_message_id(MessageId::try_from(id.to_string()).map_err(|_| refused("bad id"))?);
        self.pace().await;
        // The recipient list is the whole audience: the test number only.
        self.client
            .status()
            .send_raw(message.clone(), std::slice::from_ref(&self.peer), options)
            .await
            .map_err(|e| {
                refused(&format!(
                    "status not posted: {:?}",
                    std::mem::discriminant(&e)
                ))
            })?;
        let kind = if photo.is_some() { "image" } else { "text" };
        let media = nimqo_whatsapp::inbox::media_of(&message);
        self.inbox
            .store_own_status(
                id.as_str(),
                crate::unix_now(),
                kind,
                caption.map(str::to_owned),
                media,
            )
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        self.listener
            .on_chats_changed(vec![nimqo_whatsapp::inbox::STATUS.to_owned()]);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn photo(kind: FileKind, mimetype: &str) -> OutgoingFile {
        OutgoingFile {
            bytes: vec![1; 10],
            file_name: "a".into(),
            mimetype: mimetype.into(),
            caption: None,
            thumbnail: None,
            kind,
            duration_secs: None,
        }
    }

    #[test]
    fn text_or_a_jpeg_photo_within_limits() {
        assert!(check_status("hi", None).is_ok());
        assert!(check_status("  ", None).is_err());
        assert!(check_status(&"x".repeat(MAX_STATUS_CHARS + 1), None).is_err());
        assert!(check_status("", Some(&photo(FileKind::Photo, "image/jpeg"))).is_ok());
        assert!(check_status("", Some(&photo(FileKind::Photo, "image/png"))).is_err());
        assert!(check_status("", Some(&photo(FileKind::Video, "video/mp4"))).is_err());
    }
}
