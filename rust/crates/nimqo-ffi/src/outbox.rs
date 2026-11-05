//! Sending (plan 10.5). During development only the allowlisted test chat
//! may be sent to; everything else is refused before it reaches the store.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nimqo_whatsapp::inbox::Inbox;
use nimqo_whatsapp::outbox::Status;
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::Receipt;
use whatsapp_rust::types::presence::ReceiptType;
use whatsapp_rust::{Client, MessageId, SendOptions, SendRequest};

use crate::{CoreError, CoreListener};

const MAX_CHARS: usize = 1000;
/// Guard against accidental bursts (the account is real; no blasting).
const MIN_INTERVAL: Duration = Duration::from_secs(1);

/// The allowlist and burst guard. Returns the trimmed text to send.
fn check<'a>(
    chat_id: &str,
    peer_chat: &str,
    text: &'a str,
    last_send: Option<Instant>,
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
    if last_send.is_some_and(|t| t.elapsed() < MIN_INTERVAL) {
        return Err("Wait a moment between messages.");
    }
    Ok(text)
}

pub struct Sender {
    pub inbox: Inbox,
    pub client: Arc<Client>,
    pub peer: Jid,
    pub listener: Arc<dyn CoreListener>,
    last_send: Mutex<Option<Instant>>,
    /// One flush at a time, so a message is never sent twice concurrently.
    flushing: tokio::sync::Mutex<()>,
}

impl Sender {
    pub fn new(
        inbox: Inbox,
        client: Arc<Client>,
        peer: Jid,
        listener: Arc<dyn CoreListener>,
    ) -> Self {
        Self {
            inbox,
            client,
            peer,
            listener,
            last_send: Mutex::new(None),
            flushing: tokio::sync::Mutex::new(()),
        }
    }

    pub fn peer_chat(&self) -> String {
        self.peer.to_non_ad_string()
    }

    /// Validates and stores the message as pending. The caller then flushes.
    pub fn enqueue(&self, chat_id: &str, text: &str) -> Result<(), CoreError> {
        let refused = |reason: &str| CoreError::SendRefused {
            reason: reason.to_owned(),
        };
        let mut last = self
            .last_send
            .lock()
            .map_err(|_| refused("internal lock poisoned"))?;
        let text = check(chat_id, &self.peer_chat(), text, *last).map_err(refused)?;
        let id = self.client.generate_message_id();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX));
        self.inbox
            .enqueue(chat_id, id.as_str(), now, text)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        *last = Some(Instant::now());
        drop(last);
        self.listener.on_chats_changed(vec![chat_id.to_owned()]);
        Ok(())
    }

    /// Sends every pending message. Called after enqueueing and whenever the
    /// connection comes up, so messages written offline go out later.
    pub async fn flush(&self) {
        let _guard = self.flushing.lock().await;
        let pending = match self.inbox.pending() {
            Ok(p) => p,
            Err(e) => return log::warn!("outbox unreadable: {e:#}"),
        };
        let peer_chat = self.peer_chat();
        let mut changed = Vec::new();
        for p in pending {
            let outcome = if p.chat == peer_chat {
                self.send(&p.id, p.body).await
            } else {
                // Defense in depth: never send to anyone else, whatever is stored.
                Err("not the test chat".to_owned())
            };
            let result = match outcome {
                Ok(()) => self.inbox.advance(&p.id, Status::Sent).map(|_| ()),
                Err(e) => {
                    log::warn!("send failed: {e}");
                    self.inbox.attempt_failed(&p.id)
                }
            };
            if let Err(e) = result {
                log::warn!("outbox not updated: {e:#}");
            }
            changed.push(p.chat);
        }
        changed.dedup();
        if !changed.is_empty() {
            self.listener.on_chats_changed(changed);
        }
    }

    async fn send(&self, id: &str, body: String) -> Result<(), String> {
        let id = MessageId::try_from(id.to_owned()).map_err(|e| format!("{e:?}"))?;
        let request = SendRequest::new(&self.peer, wa::Message::text(body))
            .with_options(SendOptions::default().with_message_id(id));
        // Only the error kind is logged; it can carry the recipient.
        self.client
            .send(request)
            .await
            .map(|_| ())
            .map_err(|e| format!("{:?}", std::mem::discriminant(&e)))
    }

    /// Delivered and read receipts for own messages.
    pub fn on_receipt(&self, receipt: &Receipt) {
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
        assert_eq!(check(peer, peer, "  hi ", None), Ok("hi"));
        assert!(check("62999@s.whatsapp.net", peer, "hi", None).is_err());
        assert!(check("1-2@g.us", peer, "hi", None).is_err());
        assert!(check(peer, peer, "   ", None).is_err());
        assert!(check(peer, peer, &"x".repeat(MAX_CHARS + 1), None).is_err());
        assert!(
            check(peer, peer, "hi", Some(Instant::now())).is_err(),
            "burst"
        );
    }
}
