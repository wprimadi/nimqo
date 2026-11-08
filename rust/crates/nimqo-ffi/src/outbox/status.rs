//! Posting own status updates, to the audience the phone's status privacy
//! names (My contacts, My contacts except…, Only share with…). When that is
//! not known, or cannot be applied exactly, nothing is posted.

use whatsapp_rust::media::{ImageOptions, image_message};
use whatsapp_rust::prelude::wa;
use whatsapp_rust::prelude::wa::message::extended_text_message::FontType;
use whatsapp_rust::wacore::download::MediaType;
use whatsapp_rust::{MessageId, StatusPrivacySetting, StatusSendOptions, UploadOptions};

use whatsapp_rust::prelude::wa::sync_action_value::status_privacy_action::StatusDistributionMode as Mode;

use whatsapp_rust::Jid;

use super::Sender;
use super::files::{FileKind, OutgoingFile, check_file, storage};
use crate::CoreError;

/// What the phone allows in a text status.
const MAX_STATUS_CHARS: usize = 700;
/// The typeface of a text status; the phone draws it in its own fonts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StatusFont {
    Sans,
    Bold,
    Serif,
    Mono,
    Script,
}

impl StatusFont {
    fn wire(self) -> FontType {
        match self {
            Self::Sans => FontType::System,
            Self::Bold => FontType::SystemBold,
            Self::Serif => FontType::CalistogaRegular,
            Self::Mono => FontType::CourierprimeBold,
            Self::Script => FontType::MorningbreezeRegular,
        }
    }
}

/// A text status, or a photo with an optional caption.
fn check_status(text: &str, photo: Option<&OutgoingFile>) -> Result<(), &'static str> {
    if text.chars().count() > MAX_STATUS_CHARS {
        return Err("A status can have at most 700 characters.");
    }
    match photo {
        Some(p) if p.kind != FileKind::Photo => Err("Only photos can be posted as a status here."),
        Some(p) => check_file(p),
        None if text.trim().is_empty() => Err("The status is empty."),
        None => Ok(()),
    }
}

/// The contacts minus everyone hidden (each with all their known
/// addresses). None when a hidden person matches no contact under any
/// known address: they may be a contact stored under the other one, so
/// leaving them out can't be made sure of.
fn contacts_except(contacts: Vec<String>, hidden: &[Vec<String>]) -> Option<Vec<String>> {
    if hidden
        .iter()
        .any(|aliases| aliases.len() == 1 && !contacts.contains(&aliases[0]))
    {
        return None;
    }
    Some(
        contacts
            .into_iter()
            .filter(|c| !hidden.iter().flatten().any(|h| h == c))
            .collect(),
    )
}

impl Sender {
    /// Who may see a new status, per the phone's status privacy.
    fn audience(&self) -> Result<(StatusPrivacySetting, Vec<Jid>), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        let Some(a) = self.client.status().audience() else {
            return Err(refused(
                "NIMQO doesn't know your status privacy yet. Open Settings > Privacy > Status on your phone once.",
            ));
        };
        let mode = a.mode.or_else(|| a.modes.first().copied());
        let is = |m: Mode| mode == Some(m.into());
        let (setting, jids) = if is(Mode::CONTACTS) {
            (
                StatusPrivacySetting::Contacts,
                self.inbox.contact_jids().map_err(storage)?,
            )
        } else if is(Mode::DENY_LIST) {
            let contacts = self.inbox.contact_jids().map_err(storage)?;
            let mut hidden = Vec::new();
            for jid in &a.user_jid {
                hidden.push(self.inbox.aliases(jid).map_err(storage)?);
            }
            let allowed = contacts_except(contacts, &hidden).ok_or_else(|| {
                refused("Someone you hide your status from can't be matched here yet, so nothing was posted.")
            })?;
            (StatusPrivacySetting::DenyList, allowed)
        } else if is(Mode::ALLOW_LIST) {
            (StatusPrivacySetting::AllowList, a.user_jid.clone())
        } else if is(Mode::CUSTOM_LIST) {
            let chosen = a
                .custom_lists
                .iter()
                .filter(|l| l.is_selected == Some(true))
                .flat_map(|l| l.user_jid.iter().cloned())
                .collect();
            (StatusPrivacySetting::AllowList, chosen)
        } else {
            return Err(refused(
                "This status audience (close friends) isn't supported yet.",
            ));
        };
        let jids: Vec<Jid> = jids.iter().filter_map(|j| j.parse().ok()).collect();
        if jids.is_empty() {
            return Err(refused("Nobody is in your status audience."));
        }
        Ok((setting, jids))
    }

    /// Posts a status update to the phone's status audience, and keeps it
    /// under My Status.
    pub async fn post_status(
        &self,
        text: &str,
        photo: Option<&OutgoingFile>,
        background: u32,
        font: StatusFont,
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
                // Opaque, so the text always sits on the colour shown.
                m.background_argb = Some(background | 0xFF00_0000);
                m.font = Some(font.wire());
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
        let (privacy, audience) = self.audience()?;
        let id = self.client.generate_message_id();
        let options = StatusSendOptions::default()
            .with_privacy(privacy)
            .with_message_id(MessageId::try_from(id.to_string()).map_err(|_| refused("bad id"))?);
        self.client
            .status()
            .send_raw(message.clone(), &audience, options)
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
    fn hidden_people_never_get_a_status() {
        let c = |v: &[&str]| v.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        let contacts = c(&["1@s.whatsapp.net", "2@s.whatsapp.net", "3@lid"]);
        assert_eq!(
            contacts_except(
                contacts.clone(),
                &[c(&["9@lid", "2@s.whatsapp.net"]), c(&["3@lid"])]
            ),
            Some(c(&["1@s.whatsapp.net"]))
        );
        // Not matchable: could be "1" under its LID.
        assert_eq!(contacts_except(contacts, &[c(&["8@lid"])]), None);
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
