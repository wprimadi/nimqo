//! Chat and message actions: pin, archive, star, edit, delete for everyone,
//! and forward. Pins, archives, and stars are synced from and to the
//! account's other devices, like mutes.

use whatsapp_rust::prelude::*;
use whatsapp_rust::{EditRequest, Jid, MessageId, MessageRef, SyncActionMessageRange};

use super::{Sender, check};
use crate::CoreError;

/// How long WhatsApp lets a message be edited, and deleted for everyone.
pub const EDIT_WINDOW_SECS: i64 = 15 * 60;
pub const REVOKE_WINDOW_SECS: i64 = 60 * 60 * 60;
/// WhatsApp forwards to at most five chats at a time.
const MAX_FORWARD_TO: usize = 5;

fn refused(reason: impl Into<String>) -> CoreError {
    CoreError::SendRefused {
        reason: reason.into(),
    }
}

fn storage(e: impl std::fmt::Display) -> CoreError {
    CoreError::Storage {
        detail: format!("{e:#}"),
    }
}

impl Sender {
    /// A chat was pinned or unpinned on one of the account's devices.
    pub async fn on_pin(&self, jid: &Jid, pinned: bool, at_ms: i64) {
        let chat = nimqo_whatsapp::lids::phone_chat(&self.inbox, &self.client, jid).await;
        match self.inbox.set_pinned(&chat, pinned.then_some(at_ms)) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("pin not stored: {e:#}"),
        }
    }

    /// A chat was archived or unarchived on one of the account's devices.
    pub async fn on_archive(&self, jid: &Jid, archived: bool) {
        let chat = nimqo_whatsapp::lids::phone_chat(&self.inbox, &self.client, jid).await;
        match self.inbox.set_archived(&chat, archived) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("archive not stored: {e:#}"),
        }
    }

    /// A message was starred or unstarred on one of the account's devices.
    pub async fn on_star(&self, jid: &Jid, id: &str, starred: bool) {
        let chat = nimqo_whatsapp::lids::phone_chat(&self.inbox, &self.client, jid).await;
        match self.inbox.set_starred(&chat, id, starred) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("star not stored: {e:#}"),
        }
    }

    pub async fn set_pinned(&self, chat: &str, pinned: bool) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let actions = self.client.chat_actions();
        let done = if pinned {
            actions.pin_chat(&jid).await
        } else {
            actions.unpin_chat(&jid).await
        };
        done.map_err(|e| refused(format!("pin not changed: {e}")))?;
        let at = pinned.then(|| crate::unix_now().saturating_mul(1000));
        self.inbox.set_pinned(chat, at).map_err(|e| storage(&e))?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    pub async fn set_archived(&self, chat: &str, archived: bool) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        // The phone applies an archive up to the newest message it names.
        let range = self
            .inbox
            .latest(chat)
            .map_err(|e| storage(&e))?
            .map(|(id, from_me, ts)| {
                let mut key = wa::MessageKey::default();
                key.remote_jid = Some(chat.to_owned());
                key.from_me = Some(from_me);
                key.id = Some(id);
                let mut message = wa::sync_action_value::SyncActionMessage::default();
                message.key = whatsapp_rust::buffa::MessageField::some(key);
                message.timestamp = Some(ts);
                let mut range = SyncActionMessageRange::default();
                range.last_message_timestamp = Some(ts);
                range.messages = vec![message];
                range
            });
        let actions = self.client.chat_actions();
        let done = if archived {
            actions.archive_chat(&jid, range).await
        } else {
            actions.unarchive_chat(&jid, range).await
        };
        done.map_err(|e| refused(format!("archive not changed: {e}")))?;
        self.inbox
            .set_archived(chat, archived)
            .map_err(|e| storage(&e))?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    pub async fn set_starred(&self, chat: &str, seq: i64, starred: bool) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let m = self.original(chat, seq)?;
        let sender = Self::author(&jid, &m)?;
        let id = MessageId::new(&m.id).map_err(|e| refused(format!("{e:?}")))?;
        let target = MessageRef::new(&jid, id, sender.as_ref(), m.from_me)
            .map_err(|e| refused(format!("{e:?}")))?;
        let actions = self.client.chat_actions();
        let done = if starred {
            actions.star_message(&target).await
        } else {
            actions.unstar_message(&target).await
        };
        done.map_err(|e| refused(format!("star not changed: {e}")))?;
        self.inbox
            .set_starred(chat, &m.id, starred)
            .map_err(|e| storage(&e))?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Replaces the text of own message `seq`, within WhatsApp's window.
    pub async fn edit(&self, chat: &str, seq: i64, text: &str) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let text = check(text).map_err(refused)?;
        let m = self.original(chat, seq)?;
        if !m.from_me || m.kind != "text" {
            return Err(refused("Only your own text messages can be edited."));
        }
        if crate::unix_now() - m.ts > EDIT_WINDOW_SECS {
            return Err(refused(
                "Messages can be edited for 15 minutes after sending.",
            ));
        }
        let id = MessageId::new(&m.id).map_err(|e| refused(format!("{e:?}")))?;
        let target =
            MessageRef::new(&jid, id, None, true).map_err(|e| refused(format!("{e:?}")))?;
        self.client
            .edit_message(EditRequest::new(target, wa::Message::text(text.to_owned())))
            .await
            .map_err(|e| refused(format!("not edited: {:?}", std::mem::discriminant(&e))))?;
        self.inbox
            .edit_own(chat, &m.id, text)
            .map_err(|e| storage(&e))?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Deletes own message `seq` for everyone, within WhatsApp's window.
    pub async fn revoke(&self, chat: &str, seq: i64) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let m = self.original(chat, seq)?;
        if !m.from_me {
            return Err(refused(
                "Only your own messages can be deleted for everyone.",
            ));
        }
        if crate::unix_now() - m.ts > REVOKE_WINDOW_SECS {
            return Err(refused("This message is too old to delete for everyone."));
        }
        let id = MessageId::new(&m.id).map_err(|e| refused(format!("{e:?}")))?;
        let target =
            MessageRef::new(&jid, id, None, true).map_err(|e| refused(format!("{e:?}")))?;
        self.client
            .revoke_message(&target)
            .await
            .map_err(|e| refused(format!("not deleted: {:?}", std::mem::discriminant(&e))))?;
        self.inbox
            .revoke_own(chat, &m.id)
            .map_err(|e| storage(&e))?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Queues a forwarded copy of message `seq` of `from` in each of `to`.
    /// The caller then flushes.
    pub fn forward(&self, from: &str, seq: i64, to: Vec<String>) -> Result<(), CoreError> {
        if to.is_empty() || to.len() > MAX_FORWARD_TO {
            return Err(refused("Forward to one to five chats at a time."));
        }
        // Every target is checked before anything is queued.
        for chat in &to {
            Self::may_send(chat)?;
        }
        let m = self.original(from, seq)?;
        let forwardable = nimqo_whatsapp::forward::FORWARDABLE.contains(&m.kind.as_str())
            && nimqo_whatsapp::forward::forwarded(&m.kind, m.body.as_deref(), m.media.as_deref())
                .is_some();
        if !forwardable {
            return Err(refused("This message can't be forwarded."));
        }
        for chat in &to {
            let id = self.client.generate_message_id();
            self.inbox
                .enqueue_forward(chat, id.as_str(), crate::unix_now(), &m)
                .map_err(|e| storage(&e))?;
        }
        self.listener.on_chats_changed(to);
        Ok(())
    }

    /// Pins, archives, and stars set before NIMQO kept them: fetch them
    /// once. A read, nothing is sent.
    pub async fn load_flags_once(&self) {
        if !self
            .inbox
            .first_time("load pins and stars")
            .unwrap_or(false)
        {
            return;
        }
        match self
            .client
            .resync_app_state(
                [
                    whatsapp_rust::WAPatchName::RegularLow,
                    whatsapp_rust::WAPatchName::RegularHigh,
                ],
                whatsapp_rust::AppStateResyncMode::Snapshot,
            )
            .await
        {
            Ok(_) => log::info!("pins and stars loaded"),
            Err(e) => log::warn!("pins and stars not loaded: {e}"),
        }
    }

    fn original(&self, chat: &str, seq: i64) -> Result<nimqo_whatsapp::replies::Quoted, CoreError> {
        self.inbox
            .quoted_by_seq(chat, seq)
            .map_err(|e| storage(&e))?
            .ok_or_else(|| refused("That message is gone."))
    }

    /// Who wrote `m`, as a reference needs it: in a group, the member.
    fn author(chat: &Jid, m: &nimqo_whatsapp::replies::Quoted) -> Result<Option<Jid>, CoreError> {
        if m.from_me || chat.server != whatsapp_rust::Server::Group {
            return Ok(None);
        }
        m.sender
            .parse()
            .map(Some)
            .map_err(|_| refused("The sender of that message is unknown."))
    }
}
