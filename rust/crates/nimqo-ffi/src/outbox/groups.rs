//! Group administration: name and description, who may send or edit, members
//! and their roles, the invite link, leaving, and new groups. The server
//! decides who may do what; a refusal comes back as `SendRefused`.

use whatsapp_rust::{
    GroupCreateOptions, GroupDescription, GroupParticipantOptions, GroupSubject, Jid,
    PreviousDescription,
};

use super::Sender;
use crate::CoreError;

/// What a group setting toggles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum GroupSetting {
    /// Only admins can send messages.
    AnnounceOnly,
    /// Only admins can edit the group's info.
    Locked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MemberChange {
    Add,
    Remove,
    Promote,
    Demote,
}

/// WhatsApp's own limit for a group's size.
const MAX_MEMBERS: usize = 1024;

fn refused(reason: impl Into<String>) -> CoreError {
    CoreError::SendRefused {
        reason: reason.into(),
    }
}

fn group(chat: &str) -> Result<Jid, CoreError> {
    if !chat.ends_with("@g.us") {
        return Err(refused("That is not a group."));
    }
    chat.parse().map_err(|_| refused("That is not a group."))
}

/// A person, by number or LID; never a group, status, or channel.
fn person(id: &str) -> Result<Jid, CoreError> {
    let ok = id.ends_with("@s.whatsapp.net") || id.ends_with("@lid");
    ok.then(|| id.parse().ok())
        .flatten()
        .ok_or_else(|| refused("Only people can be members of a group."))
}

/// Logs the error kind only: a server error can carry numbers.
fn failed(what: &str, e: &impl std::fmt::Debug) -> CoreError {
    log::warn!("{what} failed: {:?}", std::mem::discriminant(e));
    refused(format!(
        "WhatsApp didn't accept the change ({what}). You may need to be an admin."
    ))
}

impl Sender {
    /// A group changed, by anyone: a new name goes to the chat list, and
    /// the app reads the group's info again.
    pub fn on_group_update(
        &self,
        jid: &Jid,
        action: &whatsapp_rust::wacore::stanza::groups::GroupNotificationAction,
    ) {
        use whatsapp_rust::wacore::stanza::groups::GroupNotificationAction as Action;
        let chat = jid.to_non_ad_string();
        if let Action::Subject { subject, .. } = action
            && !subject.trim().is_empty()
            && let Err(e) = self.inbox.set_chat_name(&chat, subject.trim())
        {
            log::warn!("group name not stored: {e:#}");
        }
        self.listener.on_chats_changed(vec![chat]);
    }

    pub async fn set_group_subject(&self, chat: &str, subject: &str) -> Result<(), CoreError> {
        let jid = group(chat)?;
        let subject = subject.trim();
        if subject.is_empty() {
            return Err(refused("A group needs a name."));
        }
        let valid = GroupSubject::new(subject).map_err(|_| refused("That name is too long."))?;
        self.client
            .groups()
            .set_subject(jid, valid)
            .await
            .map_err(|e| failed("name", &e))?;
        self.inbox
            .set_chat_name(chat, subject)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// An empty `text` removes the description.
    pub async fn set_group_description(&self, chat: &str, text: &str) -> Result<(), CoreError> {
        let jid = group(chat)?;
        let text = text.trim();
        let description = if text.is_empty() {
            None
        } else {
            Some(
                GroupDescription::new(text)
                    .map_err(|_| refused("That description is too long."))?,
            )
        };
        self.client
            .groups()
            .set_description(jid, description, PreviousDescription::Resolve)
            .await
            .map_err(|e| failed("description", &e))
    }

    pub async fn set_group_setting(
        &self,
        chat: &str,
        setting: GroupSetting,
        on: bool,
    ) -> Result<(), CoreError> {
        let jid = group(chat)?;
        let groups = self.client.groups();
        match setting {
            GroupSetting::AnnounceOnly => groups.set_announce(jid, on).await,
            GroupSetting::Locked => groups.set_locked(jid, on).await,
        }
        .map_err(|e| failed("setting", &e))
    }

    /// Changes `members` (person ids); returns how many the server turned
    /// down (their privacy can keep them from being added, for one).
    pub async fn change_members(
        &self,
        chat: &str,
        members: &[String],
        change: MemberChange,
    ) -> Result<u32, CoreError> {
        let jid = group(chat)?;
        if members.is_empty() || members.len() > MAX_MEMBERS {
            return Err(refused("Choose who to change."));
        }
        let people = members
            .iter()
            .map(|m| person(m))
            .collect::<Result<Vec<_>, _>>()?;
        let groups = self.client.groups();
        let answers = match change {
            MemberChange::Add => groups.add_participants(&jid, &people).await,
            MemberChange::Remove => groups.remove_participants(&jid, &people).await,
            MemberChange::Promote => groups.promote_participants(&jid, &people).await,
            MemberChange::Demote => groups.demote_participants(&jid, &people).await,
        }
        .map_err(|e| failed("members", &e))?;
        let refused = answers.iter().filter(|a| !a.is_ok()).count();
        Ok(u32::try_from(refused).unwrap_or(u32::MAX))
    }

    /// The group's invite link; `reset` makes a new one and the old one
    /// stops working.
    pub async fn group_invite_link(&self, chat: &str, reset: bool) -> Result<String, CoreError> {
        let jid = group(chat)?;
        let code = self
            .client
            .groups()
            .get_invite_link(jid, reset)
            .await
            .map_err(|e| failed("invite link", &e))?;
        // The server answers with the code alone or the whole link.
        Ok(if code.starts_with("https://") {
            code
        } else {
            format!("https://chat.whatsapp.com/{code}")
        })
    }

    pub async fn leave_group(&self, chat: &str) -> Result<(), CoreError> {
        let jid = group(chat)?;
        self.client
            .groups()
            .leave(jid)
            .await
            .map_err(|e| failed("leave", &e))
    }

    /// Creates a group named `subject` with `members` (person ids) and
    /// returns its chat id.
    pub async fn create_group(
        &self,
        subject: &str,
        members: &[String],
    ) -> Result<String, CoreError> {
        let subject = subject.trim();
        if subject.is_empty() {
            return Err(refused("A group needs a name."));
        }
        GroupSubject::new(subject).map_err(|_| refused("That name is too long."))?;
        if members.is_empty() || members.len() > MAX_MEMBERS {
            return Err(refused("Choose at least one person."));
        }
        let participants = members
            .iter()
            .map(|m| person(m).map(GroupParticipantOptions::new))
            .collect::<Result<Vec<_>, _>>()?;
        let options = GroupCreateOptions::builder()
            .subject(subject)
            .participants(participants)
            .build();
        let created = self
            .client
            .groups()
            .create_group(options)
            .await
            .map_err(|e| failed("new group", &e))?;
        let chat = created.metadata.id.to_non_ad_string();
        self.inbox
            .set_chat_name(&chat, subject)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        Ok(chat)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_groups_and_people() {
        assert!(group("123-456@g.us").is_ok());
        assert!(group("62811@s.whatsapp.net").is_err());
        assert!(group("status@broadcast").is_err());
        assert!(person("62811@s.whatsapp.net").is_ok());
        assert!(person("999@lid").is_ok());
        assert!(person("123-456@g.us").is_err());
        assert!(person("1@newsletter").is_err());
    }
}
