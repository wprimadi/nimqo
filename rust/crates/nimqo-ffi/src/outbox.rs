//! Sending (plan 10.5). During development only the allowlisted test chat
//! may be sent to; everything else is refused before it reaches the store.
//!
//! A successful `send` only means the stanza was written to the socket; on a
//! dead connection that succeeds and the message is lost. So a message stays
//! pending until the server acks it, and anything unacked is sent again (same
//! id) when the connection comes back.
//!
//! Messages are queued at once (the UI shows them as sending) and sent one
//! at a time, at least `MIN_INTERVAL` apart. The anti-burst guard is a cap
//! on unsent messages rather than a refusal of fast typing.

use std::collections::HashSet;

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nimqo_whatsapp::attachments::Attachments;
use nimqo_whatsapp::inbox::Inbox;
use nimqo_whatsapp::lids;
use nimqo_whatsapp::outbox::Pending;
use nimqo_whatsapp::outbox::Status;
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{Receipt, ServerAck};
use whatsapp_rust::types::presence::ReceiptType;
use whatsapp_rust::{Client, MessageId, SendOptions, SendRequest};

use crate::{CoreError, CoreListener};

mod files;
pub use files::OutgoingFile;

const MAX_CHARS: usize = 1000;
/// Spacing between sends (the account is real; no blasting).
const MIN_INTERVAL: Duration = Duration::from_secs(1);
/// Unsent messages allowed at once; stops runaway repeats, not typing.
const MAX_QUEUED: usize = 10;

/// The allowlist and queue cap. Returns the trimmed text to send.
fn check<'a>(
    chat_id: &str,
    peer_chat: &str,
    text: &'a str,
    queued: usize,
) -> Result<&'a str, &'static str> {
    if chat_id != peer_chat {
        return Err("During development NIMQO only sends to the test number.");
    }
    let text = text.trim();
    if text.is_empty() {
        return Err("The message is empty.");
    }
    if text.chars().count() > MAX_CHARS {
        return Err("The message is longer than 1000 characters.");
    }
    if queued >= MAX_QUEUED {
        return Err("Too many messages waiting to send. Try again when they have gone out.");
    }
    Ok(text)
}

pub struct Sender {
    pub inbox: Inbox,
    pub client: Arc<Client>,
    pub peer: Jid,
    pub listener: Arc<dyn CoreListener>,
    attachments: Arc<Attachments>,
    /// True while the connection is up; sends wait for it otherwise, so a
    /// message written offline does not burn its retries.
    online: Box<dyn Fn() -> bool + Send + Sync>,
    /// When the last message was written; paces the next one.
    last_send: Mutex<Option<Instant>>,
    /// Makes the queue-cap check and the insert one step.
    queueing: Mutex<()>,
    /// Written on this connection, waiting for the server's ack.
    in_flight: Mutex<HashSet<String>>,
    /// One flush at a time, so a message is never sent twice concurrently.
    flushing: tokio::sync::Mutex<()>,
}

impl Sender {
    pub fn new(
        inbox: Inbox,
        client: Arc<Client>,
        peer: Jid,
        listener: Arc<dyn CoreListener>,
        attachments: Arc<Attachments>,
        online: Box<dyn Fn() -> bool + Send + Sync>,
    ) -> Self {
        Self {
            inbox,
            client,
            peer,
            listener,
            attachments,
            online,
            last_send: Mutex::new(None),
            queueing: Mutex::new(()),
            in_flight: Mutex::new(HashSet::new()),
            flushing: tokio::sync::Mutex::new(()),
        }
    }

    pub fn peer_chat(&self) -> String {
        self.peer.to_non_ad_string()
    }

    /// Validates and stores the message as pending. The caller then flushes.
    pub fn enqueue(
        &self,
        chat_id: &str,
        text: &str,
        reply_to: Option<i64>,
    ) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        let _queueing = self
            .queueing
            .lock()
            .map_err(|_| refused("internal lock poisoned"))?;
        let queued = self
            .inbox
            .pending()
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?
            .len();
        let text = check(chat_id, &self.peer_chat(), text, queued).map_err(refused)?;
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
        let peer_chat = self.peer_chat();
        let mut changed = Vec::new();
        for p in pending {
            if self.in_flight().is_some_and(|f| f.contains(&p.id)) {
                continue; // written already; waiting for the ack
            }
            let outcome = if p.chat == peer_chat {
                self.pace().await;
                self.send(&p).await
            } else {
                // Defense in depth: never send to anyone else, whatever is stored.
                Err("not the test chat".to_owned())
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
        changed.dedup();
        if !changed.is_empty() {
            self.listener.on_chats_changed(changed);
        }
    }

    async fn send(&self, p: &Pending) -> Result<(), String> {
        let id = MessageId::try_from(p.id.clone()).map_err(|e| format!("{e:?}"))?;
        let mut options = SendOptions::default().with_message_id(id);
        // A chat with disappearing messages on: ours disappear too.
        if let Some(seconds) = p.timer.and_then(|t| u32::try_from(t).ok()) {
            options = options.with_ephemeral_expiration(seconds);
        }
        let message = if p.kind == "text" {
            let body = p.body.clone().unwrap_or_default();
            match self.quote_context(p) {
                Some(context) => wa::Message::text_with_context(body, context),
                None => wa::Message::text(body),
            }
        } else {
            self.file_message(p).await?
        };
        let request = SendRequest::new(&self.peer, message.clone()).with_options(options);
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

    /// Waits until `MIN_INTERVAL` has passed since the previous send, then
    /// claims the slot. Only called under the flush lock.
    async fn pace(&self) {
        let wait = self
            .last_send
            .lock()
            .ok()
            .and_then(|l| l.and_then(|t| MIN_INTERVAL.checked_sub(t.elapsed())));
        if let Some(wait) = wait {
            tokio::time::sleep(wait).await;
        }
        if let Ok(mut l) = self.last_send.lock() {
            *l = Some(Instant::now());
        }
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
                self.inbox
                    .attempt_failed(&ack.id)
                    .map(|()| Some(self.peer_chat()))
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

    /// Fetch the whole address book once per launch: live updates alone miss
    /// entries (names saved by LID were dropped before). A read, nothing is
    /// sent. ponytail: one snapshot per launch; track a sync version if it
    /// gets slow.
    pub async fn load_contacts_once(&self) {
        static DONE: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
        if let Ok((total, by_lid, matched, by_pn, direct, pushed)) = self.inbox.contact_stats() {
            log::info!(
                "address book: {total} names, {by_lid} by LID, {by_pn} by number, \
                 {matched} on chats; {direct} 1:1 chats, {pushed} with a push name"
            );
        }
        if DONE.swap(true, std::sync::atomic::Ordering::Relaxed) {
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
            Ok(_) => {
                let n = self.inbox.contact_count().unwrap_or(0);
                log::info!("address book loaded: {n} names");
            }
            Err(e) => log::warn!("address book not loaded: {e}"),
        }
    }

    /// Read receipts to the test chat only (the caller checks the chat).
    /// ponytail: lost when offline; queue them like messages if that matters.
    pub async fn send_read_receipts(&self, ids: Vec<String>) {
        let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
        if let Err(e) = self.client.mark_as_read(&self.peer, None, &ids).await {
            log::warn!("read receipts not sent: {}", e.root_cause());
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
        let mut changed = Vec::new();
        for id in &receipt.message_ids {
            match self.inbox.advance(id.as_str(), to) {
                Ok(Some(chat)) => changed.push(chat),
                Ok(None) => {}
                Err(e) => log::warn!("receipt not stored: {e:#}"),
            }
        }
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
    fn only_the_test_chat_and_sane_messages_pass() {
        let peer = "62811@s.whatsapp.net";
        assert_eq!(check(peer, peer, "  hi ", 0), Ok("hi"));
        assert_eq!(check(peer, peer, "hi", MAX_QUEUED - 1), Ok("hi"));
        assert!(check("62999@s.whatsapp.net", peer, "hi", 0).is_err());
        assert!(check("1-2@g.us", peer, "hi", 0).is_err());
        assert!(check(peer, peer, "   ", 0).is_err());
        assert!(check(peer, peer, &"x".repeat(MAX_CHARS + 1), 0).is_err());
        assert!(check(peer, peer, "hi", MAX_QUEUED).is_err(), "queue cap");
    }
}
