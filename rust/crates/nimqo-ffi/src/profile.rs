//! This account's own profile: its name, About and picture, as others see
//! them, changed from here for every device.

use std::sync::Arc;

use whatsapp_rust::features::TextStatusExpiry;

use crate::{Core, CoreError, unix_now};

#[derive(Debug, uniffi::Record)]
pub struct MyProfile {
    /// The account's own chat id, for its picture.
    pub id: String,
    pub name: String,
    /// Nil when unset, or when it could not be fetched (`about_known`).
    pub about: Option<String>,
    pub about_known: bool,
}

/// WhatsApp's own limits.
const MAX_NAME: usize = 25;
const MAX_ABOUT: usize = 139;
/// A profile picture is a square JPEG; WhatsApp scales it to 640 px.
const MAX_PHOTO_BYTES: usize = 2 * 1024 * 1024;

fn refused(reason: impl Into<String>) -> CoreError {
    CoreError::SendRefused {
        reason: reason.into(),
    }
}

#[uniffi::export]
impl Core {
    /// The account's name, About and id. Nil before pairing.
    pub async fn my_profile(&self) -> Option<MyProfile> {
        let client = Arc::clone(&self.client);
        self.runtime
            .spawn(async move {
                let jid = client.pn()?.to_non_ad();
                let about = client
                    .contacts()
                    .get_user_info(std::slice::from_ref(&jid))
                    .await
                    .ok()
                    .map(|info| info.into_values().next().and_then(|u| u.status));
                Some(MyProfile {
                    id: jid.to_string(),
                    name: client.push_name(),
                    about_known: about.is_some(),
                    about: about.flatten(),
                })
            })
            .await
            .ok()
            .flatten()
    }

    /// Changes the name others see.
    ///
    /// # Errors
    /// `SendRefused` for an empty or too long name, or when it is not
    /// accepted.
    pub async fn set_my_name(&self, name: String) -> Result<(), CoreError> {
        let name = name.trim().to_owned();
        if name.is_empty() || name.chars().count() > MAX_NAME {
            return Err(refused("A name has 1 to 25 characters."));
        }
        let client = Arc::clone(&self.client);
        self.on_runtime(async move {
            client
                .profile()
                .set_push_name(&name)
                .await
                .map(|_| ())
                .map_err(|e| refused(format!("Name not changed: {e}")))
        })
        .await
    }

    /// Sets the About; an empty text removes it.
    ///
    /// # Errors
    /// `SendRefused` for a too long text, or when it is not accepted.
    pub async fn set_my_about(&self, text: String) -> Result<(), CoreError> {
        let text = text.trim().to_owned();
        if text.chars().count() > MAX_ABOUT {
            return Err(refused("An About has at most 139 characters."));
        }
        let client = Arc::clone(&self.client);
        self.on_runtime(async move {
            let profile = client.profile();
            let done = if text.is_empty() {
                profile.clear_text_status().await
            } else {
                profile
                    .set_text_status(&text, None, TextStatusExpiry::Never)
                    .await
            };
            done.map_err(|e| refused(format!("About not changed: {e}")))
        })
        .await
    }

    /// Sets the profile picture to `jpeg` (square, made by the app), or
    /// removes it when nil. The new one is fetched back to be shown.
    ///
    /// # Errors
    /// `SendRefused` for a picture too large, or when it is not accepted.
    pub async fn set_my_photo(&self, jpeg: Option<Vec<u8>>) -> Result<(), CoreError> {
        if jpeg
            .as_ref()
            .is_some_and(|j| j.is_empty() || j.len() > MAX_PHOTO_BYTES)
        {
            return Err(refused("The picture must be a JPEG of at most 2 MB."));
        }
        let (client, avatars) = (Arc::clone(&self.client), Arc::clone(&self.avatars));
        self.on_runtime(async move {
            let profile = client.profile();
            let done = match jpeg {
                Some(jpeg) => profile.set_profile_picture(jpeg).await.map(|_| ()),
                None => profile.remove_profile_picture().await.map(|_| ()),
            };
            done.map_err(|e| refused(format!("Picture not changed: {e}")))?;
            if let Some(jid) = client.pn() {
                let id = jid.to_non_ad().to_string();
                let _ = avatars.invalidate(&id);
                if let Err(e) = avatars.refresh(&client, &id, unix_now()).await {
                    log::info!("own picture not fetched back: {e:#}");
                }
            }
            Ok(())
        })
        .await
    }
}
