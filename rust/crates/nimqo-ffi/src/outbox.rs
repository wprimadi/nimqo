//! Sending (plan 10.5): messages, reactions, mutes, chat actions, and read
//! receipts to any person or group, as WhatsApp itself allows. Statuses, channels, and
//! broadcast lists are not chats and are refused.
//!
//! A successful `send` only means the stanza was written to the socket; on a
//! dead connection that succeeds and the message is lost. So a message stays
//! pending until the server acks it, and anything unacked is sent again (same
//! id) when the connection comes back.
//!
//! Messages are queued at once (the UI shows them as sending) and sent one
//! at a time, in order.

use std::collections::HashSet;

use std::sync::{Arc, Mutex};

use nimqo_whatsapp::attachments::Attachments;
use nimqo_whatsapp::inbox::Inbox;
use nimqo_whatsapp::lids;
use nimqo_whatsapp::outbox::Pending;
use nimqo_whatsapp::outbox::Status;
use nimqo_whatsapp::receipts::Seen;
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{Receipt, ServerAck};
use whatsapp_rust::types::presence::ReceiptType;
use whatsapp_rust::{Client, MessageId, SendOptions, SendRequest};

use crate::{CoreError, CoreListener};

mod actions;
pub use actions::{EDIT_WINDOW_SECS, REVOKE_WINDOW_SECS};
mod files;
mod groups;
mod status;
mod voice;
pub use files::OutgoingFile;
pub use groups::{GroupSetting, MemberChange};
pub use status::StatusFont;

/// WhatsApp's own limit for a text message.
const MAX_CHARS: usize = 65_536;

/// A person (by number or LID) or a group; never a status, channel, or
/// broadcast list.
fn chat_jid(chat_id: &str) -> Option<Jid> {
    ["@s.whatsapp.net", "@lid", "@g.us"]
        .iter()
        .any(|s| chat_id.ends_with(s))
        .then(|| chat_id.parse::<Jid>().ok())
        .flatten()
}

/// Returns the trimmed text to send.
fn check(text: &str) -> Result<&str, &'static str> {
    let text = text.trim();
    if text.is_empty() {
        return Err("The message is empty.");
    }
    if text.chars().count() > MAX_CHARS {
        return Err("The message is too long.");
    }
    Ok(text)
}

pub struct Sender {
    pub inbox: Inbox,
    pub client: Arc<Client>,
    pub listener: Arc<dyn CoreListener>,
    attachments: Arc<Attachments>,
    /// True while the connection is up; sends wait for it otherwise, so a
    /// message written offline does not burn its retries.
    online: Box<dyn Fn() -> bool + Send + Sync>,
    /// Written on this connection, waiting for the server's ack.
    in_flight: Mutex<HashSet<String>>,
    /// One flush at a time, so a message is never sent twice concurrently.
    flushing: tokio::sync::Mutex<()>,
}

impl Sender {
    pub fn new(
        inbox: Inbox,
        client: Arc<Client>,
        listener: Arc<dyn CoreListener>,
        attachments: Arc<Attachments>,
        online: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> Self {
        Self {
            inbox,
            client,
            listener,
            attachments,
            online,
            in_flight: Mutex::new(HashSet::new()),
            flushing: tokio::sync::Mutex::new(()),
        }
    }

    /// The chat's address, if it is one a message can go to: a person or
    /// a group.
    pub fn may_send(chat_id: &str) -> Result<Jid, CoreError> {
        chat_jid(chat_id).ok_or_else(|| CoreError::SendRefused {
            reason: "Messages can go to people and groups only.".into(),
        })
    }

    /// Validates and stores the message as pending, with `link`'s preview
    /// when it names a link in the text. The caller then flushes.
    pub fn enqueue(
        &self,
        chat_id: &str,
        text: &str,
        reply_to: Option<i64>,
        link: Option<nimqo_whatsapp::links::Link>,
    ) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        Self::may_send(chat_id)?;
        let text = check(text).map_err(refused)?;
        let quote = match reply_to {
            Some(seq) => Some(
                self.inbox
                    .quoted_by_seq(chat_id, seq)
                    .map_err(|e| CoreError::Storage {
                        detail: format!("{e:#}"),
                    })?
                    .ok_or_else(|| refused("The message being replied to is gone."))?,
            ),
            None => None,
        };
        let id = self.client.generate_message_id();
        self.inbox
            .enqueue_reply(
                chat_id,
                id.as_str(),
                crate::unix_now(),
                text,
                quote.as_ref(),
            )
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        if let Some(link) = link.and_then(|l| l.checked(text))
            && let Err(e) = self.inbox.set_pending_link(id.as_str(), &link)
        {
            log::warn!("link preview not kept: {e:#}");
        }
        self.listener.on_chats_changed(vec![chat_id.to_owned()]);
        Ok(())
    }

    /// Sends every pending message. Called after enqueueing and whenever the
    /// connection comes up, so messages written offline go out later.
    ///
    /// `connected` is true when called from the connect event, which can run
    /// before the state machine has seen it.
    pub async fn flush(&self, connected: bool) {
        let _guard = self.flushing.lock().await;
        if !connected && !(self.online)() {
            return; // flushed again on Connected
        }
        let pending = match self.inbox.pending() {
            Ok(p) => p,
            Err(e) => return log::warn!("outbox unreadable: {e:#}"),
        };
        let mut changed = Vec::new();
        for p in pending {
            if self.in_flight().is_some_and(|f| f.contains(&p.id)) {
                continue; // written already; waiting for the ack
            }
            let outcome = match chat_jid(&p.chat) {
                Some(to) => self.send(&p, &to).await,
                // Defense in depth: never a status or channel, whatever is stored.
                None => Err("not a person or group".to_owned()),
            };
            match outcome {
                Ok(()) => {
                    if let Some(mut f) = self.in_flight() {
                        f.insert(p.id);
                    }
                }
                Err(e) => {
                    log::warn!("send failed: {e}");
                    if let Err(e) = self.inbox.attempt_failed(&p.id) {
                        log::warn!("outbox not updated: {e:#}");
                    }
                    changed.push(p.chat);
                }
            }
        }
        changed.sort();
        changed.dedup();
        if !changed.is_empty() {
            self.listener.on_chats_changed(changed);
        }
    }

    async fn send(&self, p: &Pending, to: &Jid) -> Result<(), String> {
        let id = MessageId::try_from(p.id.clone()).map_err(|e| format!("{e:?}"))?;
        let mut options = SendOptions::default().with_message_id(id);
        // A chat with disappearing messages on: ours disappear too.
        if let Some(seconds) = p.timer.and_then(|t| u32::try_from(t).ok()) {
            options = options.with_ephemeral_expiration(seconds);
        }
        let message = if p.forwarded {
            nimqo_whatsapp::forward::forwarded(&p.kind, p.body.as_deref(), p.media.as_deref())
                .ok_or("not forwardable")?
        } else if p.kind == "video"
            && let Some(gif) = nimqo_whatsapp::forward::gif(p.media.as_deref().unwrap_or_default())
        {
            gif
        } else if p.kind == "sticker" {
            nimqo_whatsapp::forward::sticker(p.media.as_deref().unwrap_or_default())
                .ok_or("sticker not sendable")?
        } else if p.kind == "text" {
            let body = p.body.clone().unwrap_or_default();
            let mut text = match self.quote_context(p) {
                Some(context) => wa::Message::text_with_context(body, context),
                None => wa::Message::text(body),
            };
            if let Some(link) = nimqo_whatsapp::links::pending_link(p.media.as_deref()) {
                link.attach(&mut text);
            }
            text
        } else {
            self.file_message(p).await?
        };
        let request = SendRequest::new(to, message.clone()).with_options(options);
        // Only the error kind is logged; it can carry the recipient.
        self.client
            .send(request)
            .await
            .map_err(|e| format!("{:?}", std::mem::discriminant(&e)))?;
        // Keep the message as sent, so the file can be fetched again later.
        if let Some(media) = nimqo_whatsapp::inbox::media_of(&message)
            && let Err(e) = self.inbox.set_sent_media(&p.id, &media)
        {
            log::warn!("sent media not recorded: {e:#}");
        }
        Ok(())
    }

    /// The quote sent with a reply; None when it is not one, or the quoted
    /// message is gone (it is then sent as a plain message).
    fn quote_context(&self, p: &Pending) -> Option<wa::ContextInfo> {
        let quoted = self
            .inbox
            .quoted_by_id(&p.chat, p.reply_to.as_deref()?)
            .ok()??;
        let sender = if quoted.from_me {
            self.client.pn()?.to_non_ad_string()
        } else {
            quoted.sender.clone()
        };
        Some(whatsapp_rust::wacore::proto_helpers::build_quote_context(
            quoted.id.clone(),
            sender,
            &quoted.message(),
        ))
    }

    fn in_flight(&self) -> Option<std::sync::MutexGuard<'_, HashSet<String>>> {
        self.in_flight.lock().ok()
    }

    /// Unacked writes on the old connection may never have left this Mac;
    /// the next flush sends them again with the same id.
    pub fn connection_restarted(&self) {
        if let Some(mut f) = self.in_flight() {
            f.clear();
        }
    }

    /// The server took (or refused) a message: only now is it "sent".
    pub fn on_server_ack(&self, ack: &ServerAck) {
        if ack.class.as_deref() != Some("message")
            || !self.in_flight().is_some_and(|mut f| f.remove(&ack.id))
        {
            return;
        }
        let result = match &ack.error {
            None => self.inbox.advance(&ack.id, Status::Sent),
            Some(code) => {
                log::warn!("server refused a message: {code}");
                self.inbox.attempt_failed(&ack.id)
            }
        };
        match result {
            Ok(Some(chat)) => self.listener.on_chats_changed(vec![chat]),
            Ok(None) => {}
            Err(e) => log::warn!("outbox not updated: {e:#}"),
        }
    }

    /// The phone marked a chat read (app-state sync), which is how reads on
    /// the phone usually reach linked devices.
    pub async fn on_chat_marked_read(&self, jid: &Jid, read: bool, through: Option<i64>) {
        log::info!(
            "chat marked {} on another device",
            if read { "read" } else { "unread" }
        );
        if !read {
            return; // ponytail: "mark as unread" is not shown yet
        }
        let chat = lids::phone_chat(&self.inbox, &self.client, jid).await;
        match self.inbox.read_through(&chat, through) {
            Ok(true) => self.listener.on_chats_changed(vec![chat]),
            Ok(false) => {}
            Err(e) => log::warn!("read state not stored: {e:#}"),
        }
    }

    /// A contact saved, renamed, or removed in the phone's address book.
    pub async fn on_contact(&self, jid: &Jid, name: &str, pn: Option<&str>) {
        // The action can name the phone number when the jid is a LID.
        let chat = match pn.and_then(|p| p.parse::<Jid>().ok()) {
            Some(pn) if pn.is_pn() => pn.to_non_ad_string(),
            _ => lids::phone_chat(&self.inbox, &self.client, jid).await,
        };
        match self.inbox.save_contact(&chat, name) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("contact not stored: {e:#}"),
        }
    }

    /// A contact changed their disappearing-messages default.
    pub async fn on_timer(&self, jid: &Jid, seconds: u32) {
        let chat = lids::phone_chat(&self.inbox, &self.client, jid).await;
        match self.inbox.set_timer(&chat, seconds) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("timer not stored: {e:#}"),
        }
    }

    /// A chat was muted or unmuted on one of the account's devices.
    pub async fn on_mute(&self, jid: &Jid, muted: bool, end: Option<i64>) {
        let chat = lids::phone_chat(&self.inbox, &self.client, jid).await;
        let until = if muted {
            end.filter(|e| *e != 0)
                .unwrap_or(nimqo_whatsapp::mutes::FOREVER)
        } else {
            0
        };
        match self.inbox.set_mute(&chat, until) {
            Ok(()) => self.listener.on_chats_changed(vec![chat]),
            Err(e) => log::warn!("mute not stored: {e:#}"),
        }
    }

    /// Mutes `chat` on every device of the account until `until`
    /// (milliseconds since 1970, or `mutes::FOREVER`); 0 unmutes.
    pub async fn set_mute_until(&self, chat: &str, until: i64) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let actions = self.client.chat_actions();
        let done = match until {
            0 => actions.unmute_chat(&jid).await,
            nimqo_whatsapp::mutes::FOREVER => actions.mute_chat(&jid).await,
            end => actions.mute_chat_until(&jid, end).await,
        };
        done.map_err(|e| CoreError::SendRefused {
            reason: format!("mute not changed: {e}"),
        })?;
        self.inbox
            .set_mute(chat, until)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Turns disappearing messages on (`seconds`) or off (0) in `chat`, for
    /// everyone in it.
    pub async fn set_timer(&self, chat: &str, seconds: u32) -> Result<(), CoreError> {
        let jid = Self::may_send(chat)?;
        let refused = |e: String| CoreError::SendRefused {
            reason: format!("Disappearing messages not changed: {e}"),
        };
        if chat.ends_with("@g.us") {
            self.client
                .groups()
                .set_ephemeral(jid, seconds)
                .await
                .map_err(|e| refused(e.to_string()))?;
        } else {
            self.client
                .set_chat_disappearing_timer(jid, seconds)
                .await
                .map_err(|e| refused(e.to_string()))?;
        }
        self.inbox
            .set_timer(chat, seconds)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Reacts to message `seq` with `emoji`; an empty one removes this
    /// account's reaction. Only where sending is allowed.
    pub async fn react(&self, chat: &str, seq: i64, emoji: &str) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        let jid = Self::may_send(chat)?;
        // One emoji (a flag or a family is several characters, so count
        // bytes generously); anything longer is not a reaction.
        if emoji.len() > 32 || emoji.chars().any(char::is_whitespace) {
            return Err(refused("A reaction is one emoji."));
        }
        let (id, from_me, sender) = self
            .inbox
            .message_key(chat, seq)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?
            .ok_or_else(|| refused("That message is gone."))?;
        let mut key = wa::MessageKey::default();
        key.remote_jid = Some(chat.to_owned());
        key.from_me = Some(from_me);
        key.id = Some(id.clone());
        // In a group, whose message it is.
        if !from_me && chat.ends_with("@g.us") {
            key.participant = Some(sender);
        }
        self.client
            .send_reaction_raw(jid, key, emoji)
            .await
            .map_err(|e| refused(&format!("reaction not sent: {e}")))?;
        let emoji = Some(emoji).filter(|e| !e.is_empty());
        self.inbox
            .set_own_reaction(chat, &id, emoji)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        self.listener.on_chats_changed(vec![chat.to_owned()]);
        Ok(())
    }

    /// Mutes set before NIMQO kept them were synced and dropped: fetch them
    /// once. A read, nothing is sent.
    pub async fn load_mutes_once(&self) {
        if !self.inbox.first_time("load mutes").unwrap_or(false) {
            return;
        }
        match self
            .client
            .resync_app_state(
                [whatsapp_rust::WAPatchName::RegularHigh],
                whatsapp_rust::AppStateResyncMode::Snapshot,
            )
            .await
        {
            Ok(_) => log::info!("mutes loaded"),
            Err(e) => log::warn!("mutes not loaded: {e}"),
        }
    }

    /// Fetch the address book once when none is known (never stored, or
    /// emptied by a migration). A read, nothing is sent.
    pub async fn load_contacts_once(&self) {
        static DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
        if let Ok((total, by_lid, matched, by_pn, direct, pushed)) = self.inbox.contact_stats() {
            log::info!(
                "address book: {total} names, {by_lid} by LID, {by_pn} by number, \
                 {matched} on chats; {direct} 1:1 chats, {pushed} with a push name"
            );
        }
        if self.inbox.contact_count().unwrap_or(1) > 0
            || DONE.swap(true, std::sync::atomic::Ordering::Relaxed)
        {
            return;
        }
        match self
            .client
            .resync_app_state(
                [whatsapp_rust::WAPatchName::CriticalUnblockLow],
                whatsapp_rust::AppStateResyncMode::Snapshot,
            )
            .await
        {
            Ok(_) => log::info!("address book loaded"),
            Err(e) => log::warn!("address book not loaded: {e}"),
        }
    }

    /// Read receipts for `read` (sender, id) in `chat`; in a group, one per
    /// sender. Only where sending is allowed.
    /// ponytail: lost when offline; queue them like messages if that matters.
    pub async fn send_read_receipts(&self, chat: &str, read: Vec<(String, String)>) {
        let Ok(jid) = Self::may_send(chat) else {
            return;
        };
        let group = chat.ends_with("@g.us");
        let mut by_sender = std::collections::BTreeMap::<&str, Vec<&str>>::new();
        for (sender, id) in &read {
            by_sender
                .entry(if group { sender.as_str() } else { "" })
                .or_default()
                .push(id.as_str());
        }
        for (sender, ids) in by_sender {
            let participant = sender.parse::<Jid>().ok().filter(|_| group);
            if let Err(e) = self
                .client
                .mark_as_read(&jid, participant.as_ref(), &ids)
                .await
            {
                log::warn!("read receipts not sent: {}", e.root_cause());
            }
        }
    }

    /// Tells `poster` their status update `id` was viewed.
    pub async fn send_status_receipt(&self, poster: Jid, id: String) {
        let status: Jid = match nimqo_whatsapp::inbox::STATUS.parse() {
            Ok(j) => j,
            Err(_) => return,
        };
        if let Err(e) = self
            .client
            .mark_as_read(&status, Some(&poster), &[id.as_str()])
            .await
        {
            log::warn!("status view receipt not sent: {}", e.root_cause());
        }
    }

    /// Delivered and read receipts for own messages, and reads of received
    /// messages on the account's other devices.
    pub async fn on_receipt(&self, receipt: &Receipt) {
        // Diagnostics only: the type and count, never ids or addresses.
        log::info!(
            "receipt {:?} for {} message(s)",
            receipt.r#type,
            receipt.message_ids.len()
        );
        if receipt.r#type == ReceiptType::ReadSelf {
            let ids: Vec<&str> = receipt
                .message_ids
                .iter()
                .map(whatsapp_rust::CompactString::as_str)
                .collect();
            // The chat can arrive by LID; messages are stored by number.
            let chat = lids::phone_chat(&self.inbox, &self.client, &receipt.source.chat).await;
            match self.inbox.read_elsewhere(&chat, &ids) {
                Ok(true) => self.listener.on_chats_changed(vec![chat]),
                Ok(false) => {}
                Err(e) => log::warn!("read state not stored: {e:#}"),
            }
            return;
        }
        let to = match receipt.r#type {
            ReceiptType::Delivered => Status::Delivered,
            ReceiptType::Read | ReceiptType::Played => Status::Read,
            _ => return,
        };
        let seen = match receipt.r#type {
            ReceiptType::Delivered => Seen::Delivered,
            ReceiptType::Read => Seen::Read,
            _ => Seen::Played,
        };
        // Who it was: the member in a group, the other side in a chat.
        let who = lids::phone_chat(&self.inbox, &self.client, &receipt.source.sender).await;
        let at = receipt.timestamp.timestamp();
        let mut changed = Vec::new();
        for id in &receipt.message_ids {
            // Message Info's list, per recipient; the bubble's tick below.
            match self.inbox.record_receipt(id.as_str(), &who, seen, at) {
                Ok(Some(chat)) => changed.push(chat),
                Ok(None) => {}
                Err(e) => log::warn!("receipt not kept: {e:#}"),
            }
            match self.inbox.advance(id.as_str(), to) {
                Ok(Some(chat)) => changed.push(chat),
                Ok(None) => {}
                Err(e) => log::warn!("receipt not stored: {e:#}"),
            }
        }
        changed.sort();
        changed.dedup();
        if !changed.is_empty() {
            self.listener.on_chats_changed(changed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn people_and_groups_only_and_sane_messages() {
        assert!(chat_jid("62811@s.whatsapp.net").is_some());
        assert!(chat_jid("1203@g.us").is_some());
        assert!(chat_jid("178@lid").is_some());
        assert!(chat_jid("status@broadcast").is_none());
        assert!(chat_jid("1203@newsletter").is_none());
        assert!(chat_jid("123@broadcast").is_none());
        assert_eq!(check("  hi "), Ok("hi"));
        assert!(check("   ").is_err());
        assert!(check(&"x".repeat(MAX_CHARS + 1)).is_err());
    }
}
