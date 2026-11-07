//! The account's own privacy settings, as on the phone's Privacy screen.
//! Changing them touches nobody else's device.

use std::sync::Arc;

use whatsapp_rust::privacy_settings::{
    PrivacyCategory as Category, PrivacySettingsResponse, PrivacyValue as Value,
};

use crate::Core;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PrivacySetting {
    LastSeen,
    Online,
    ProfilePhoto,
    About,
    GroupAdd,
    ReadReceipts,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PrivacyChoice {
    Everyone,
    Contacts,
    /// "My contacts except…", set on the phone; shown, not chosen here.
    ContactsExcept,
    Nobody,
    SameAsLastSeen,
}

/// Each setting's current choice; nil when the server sent none.
#[derive(Debug, Default, uniffi::Record)]
pub struct PrivacySettings {
    pub last_seen: Option<PrivacyChoice>,
    pub online: Option<PrivacyChoice>,
    pub profile_photo: Option<PrivacyChoice>,
    pub about: Option<PrivacyChoice>,
    pub group_add: Option<PrivacyChoice>,
    pub read_receipts: Option<PrivacyChoice>,
}

fn category(setting: PrivacySetting) -> Category {
    match setting {
        PrivacySetting::LastSeen => Category::Last,
        PrivacySetting::Online => Category::Online,
        PrivacySetting::ProfilePhoto => Category::Profile,
        PrivacySetting::About => Category::Status,
        PrivacySetting::GroupAdd => Category::GroupAdd,
        PrivacySetting::ReadReceipts => Category::ReadReceipts,
    }
}

fn value(choice: PrivacyChoice) -> Value {
    match choice {
        PrivacyChoice::Everyone => Value::All,
        PrivacyChoice::Contacts => Value::Contacts,
        PrivacyChoice::ContactsExcept => Value::ContactBlacklist,
        PrivacyChoice::Nobody => Value::None,
        PrivacyChoice::SameAsLastSeen => Value::MatchLastSeen,
    }
}

fn choice(value: &Value) -> Option<PrivacyChoice> {
    Some(match value {
        Value::All => PrivacyChoice::Everyone,
        Value::Contacts => PrivacyChoice::Contacts,
        Value::ContactBlacklist => PrivacyChoice::ContactsExcept,
        Value::None => PrivacyChoice::Nobody,
        Value::MatchLastSeen => PrivacyChoice::SameAsLastSeen,
        _ => return None,
    })
}

fn settings(response: &PrivacySettingsResponse) -> PrivacySettings {
    let get = |s| response.get_value(&category(s)).and_then(choice);
    PrivacySettings {
        last_seen: get(PrivacySetting::LastSeen),
        online: get(PrivacySetting::Online),
        profile_photo: get(PrivacySetting::ProfilePhoto),
        about: get(PrivacySetting::About),
        group_add: get(PrivacySetting::GroupAdd),
        read_receipts: get(PrivacySetting::ReadReceipts),
    }
}

/// Whether `choice` can be set for `setting` from here: valid for it, and
/// not one that needs a list of people.
fn settable(setting: PrivacySetting, choice: PrivacyChoice) -> bool {
    choice != PrivacyChoice::ContactsExcept && category(setting).is_valid_value(&value(choice))
}

#[uniffi::export]
impl Core {
    /// The account's privacy settings, asked of the server. Nil offline.
    pub async fn privacy_settings(&self) -> Option<PrivacySettings> {
        let client = Arc::clone(&self.client);
        match self
            .runtime
            .spawn(async move { client.fetch_privacy_settings().await })
            .await
        {
            Ok(Ok(response)) => Some(settings(&response)),
            Ok(Err(e)) => {
                log::info!("privacy settings not fetched: {e}");
                None
            }
            Err(e) => {
                log::warn!("privacy task failed: {e}");
                None
            }
        }
    }

    /// Changes one of the account's privacy settings. False when refused
    /// (offline, or a choice this setting does not have).
    pub async fn set_privacy(&self, setting: PrivacySetting, choice: PrivacyChoice) -> bool {
        if !settable(setting, choice) {
            return false;
        }
        let client = Arc::clone(&self.client);
        let done = self
            .runtime
            .spawn(async move {
                client
                    .set_privacy_setting(category(setting), value(choice))
                    .await
            })
            .await;
        match done {
            Ok(Ok(_)) => {
                log::info!("privacy setting changed");
                true
            }
            Ok(Err(e)) => {
                log::info!("privacy setting not changed: {e}");
                false
            }
            Err(_) => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_phone_s_choices_can_be_set() {
        use PrivacyChoice as C;
        use PrivacySetting as S;
        assert!(settable(S::LastSeen, C::Nobody));
        assert!(settable(S::Online, C::SameAsLastSeen));
        assert!(!settable(S::Online, C::Contacts));
        assert!(!settable(S::ReadReceipts, C::Contacts));
        assert!(settable(S::ReadReceipts, C::Nobody));
        assert!(!settable(S::LastSeen, C::ContactsExcept), "needs a list");
        for c in [
            C::Everyone,
            C::Contacts,
            C::ContactsExcept,
            C::Nobody,
            C::SameAsLastSeen,
        ] {
            assert_eq!(choice(&value(c)), Some(c));
        }
    }
}
