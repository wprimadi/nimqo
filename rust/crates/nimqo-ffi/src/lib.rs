//! UniFFI surface for the Swift app (plan section 8, ADR 0001).
//!
//! The app pairs, reports connection state, shows every chat read-only, and
//! sends only to the allowlisted test number.

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use nimqo_whatsapp::attachments::Attachments;
use nimqo_whatsapp::avatars::Avatars;
use nimqo_whatsapp::inbox::{Fault, Inbox};
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::stores::{self, AlreadyRunning};
use nimqo_whatsapp::{history, lids};
use outbox::OutgoingFile;
use whatsapp_rust::Client;
use whatsapp_rust::bot::BotHandle;
use whatsapp_rust::pair_code::{PairCodeOptions, PairCodeRejection};
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{Event, EventKind};

uniffi::setup_scaffolding!();

mod chats;
mod outbox;
mod state;

pub use chats::{Chat, ChatMessage, Delivery, MessageKind, SearchHit};

pub use state::ConnectionState;
use state::Input;

/// Implemented in Swift. Called from Rust worker threads.
#[uniffi::export(with_foreign)]
pub trait CoreListener: Send + Sync {
    fn on_state(&self, state: ConnectionState);
    /// Raw pairing payload; the app renders it as a QR code.
    fn on_qr(&self, code: String, timeout_secs: u64);
    /// Eight-character code to type on the phone, after `request_pair_code`.
    fn on_pair_code(&self, code: String, timeout_secs: u64);
    /// No code is coming. `throttled` means wait before asking again.
    fn on_pair_code_error(&self, throttled: bool, retry_after_secs: Option<u64>);
    /// New messages were stored in these chats; reload what is shown.
    fn on_chats_changed(&self, chat_ids: Vec<String>);
}

/// Grouped by what the user can do about it. `detail` is for logs and bug
/// reports; it never contains message content.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum CoreError {
    /// The configured test number is not an international number.
    InvalidPeer { detail: String },
    /// The number entered for pairing is not an international number.
    InvalidPhoneNumber,
    /// Another NIMQO process (app or CLI) has the session open.
    AlreadyRunning,
    /// The Keychain key or an encrypted database is unavailable. NIMQO fails
    /// closed here and never falls back to plaintext.
    Storage { detail: String },
    /// The client could not be built or started.
    Startup { detail: String },
    /// The message was not queued; `reason` is shown to the user.
    SendRefused { reason: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (kind, detail) = match self {
            Self::InvalidPeer { detail } => ("invalid test number", detail.as_str()),
            Self::InvalidPhoneNumber => (
                "invalid phone number",
                "use the international format, e.g. +62 812 3456 7890",
            ),
            Self::AlreadyRunning => (
                "already running",
                "another NIMQO process has the session open",
            ),
            Self::Storage { detail } => ("encrypted storage unavailable", detail.as_str()),
            Self::Startup { detail } => ("cannot start", detail.as_str()),
            Self::SendRefused { reason } => ("not sent", reason.as_str()),
        };
        write!(f, "{kind}: {detail}")
    }
}

impl std::error::Error for CoreError {}

fn err<E: std::fmt::Display>(make: fn(String) -> CoreError) -> impl Fn(E) -> CoreError {
    move |e| make(format!("{e:#}"))
}

/// Current state plus the listener to tell about changes.
struct Machine {
    state: Mutex<ConnectionState>,
    listener: Arc<dyn CoreListener>,
}

impl Machine {
    fn feed(&self, input: Input) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let next = state.next(input);
        if next != *state {
            log::info!("connection {:?} -> {next:?}", *state);
            state.clone_from(&next);
            drop(state);
            self.listener.on_state(next);
        }
    }

    fn current(&self) -> ConnectionState {
        self.state.lock().map_or(
            ConnectionState::Failed {
                reason: "state lock poisoned".into(),
            },
            |s| s.clone(),
        )
    }
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: tokio::runtime::Runtime,
    handle: Mutex<Option<BotHandle>>,
    client: Arc<Client>,
    machine: Arc<Machine>,
    /// Number used for code pairing, kept to re-request when the server asks.
    pair_phone: Arc<Mutex<Option<String>>>,
    dir: PathBuf,
    inbox: Inbox,
    sender: Arc<outbox::Sender>,
    avatars: Arc<Avatars>,
    attachments: Arc<Attachments>,
    /// Data-directory lock; released on drop or after a reset.
    lock: Mutex<Option<File>>,
}

#[uniffi::export]
impl Core {
    /// Opens the encrypted stores and connects. Blocks until the connection
    /// task is running, so call it off the main thread.
    ///
    /// # Errors
    /// The peer number is invalid, another process holds the session, or the
    /// stores or client cannot start.
    #[uniffi::constructor]
    pub fn start(test_peer: &str, listener: Arc<dyn CoreListener>) -> Result<Arc<Self>, CoreError> {
        init_logging();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| CoreError::Startup {
                detail: e.to_string(),
            })?;
        listener.on_state(ConnectionState::Connecting);
        let machine = Arc::new(Machine {
            state: Mutex::new(ConnectionState::Connecting),
            listener,
        });
        let pair_phone = Arc::new(Mutex::new(None));
        let session = runtime.block_on(connect(
            test_peer,
            Arc::clone(&machine),
            Arc::clone(&pair_phone),
        ))?;
        runtime.spawn(purge_expired(
            session.inbox.clone(),
            Arc::clone(&session.attachments),
        ));
        Ok(Arc::new(Self {
            runtime,
            handle: Mutex::new(Some(session.handle)),
            client: session.client,
            machine,
            pair_phone,
            dir: session.dir,
            inbox: session.inbox,
            sender: session.sender,
            avatars: session.avatars,
            attachments: session.attachments,
            lock: Mutex::new(Some(session.lock)),
        }))
    }

    /// Chats by most recent activity. Reads the local store only.
    ///
    /// # Errors
    /// The encrypted store cannot be read.
    pub fn chats(&self) -> Result<Vec<Chat>, CoreError> {
        const LIMIT: i64 = 500;
        Ok(self
            .inbox
            .chats(LIMIT)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(Chat::from)
            .collect())
    }

    /// The latest messages of one chat, oldest first.
    ///
    /// # Errors
    /// The encrypted store cannot be read.
    pub fn messages(&self, chat_id: &str, limit: u32) -> Result<Vec<ChatMessage>, CoreError> {
        self.older_messages(chat_id, None, limit)
    }

    /// Up to `limit` messages before the one at `(timestamp_secs, seq)`, or
    /// the latest when `None`; oldest first. Fewer than `limit` means the
    /// start of the chat.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn older_messages(
        &self,
        chat_id: &str,
        before: Option<Cursor>,
        limit: u32,
    ) -> Result<Vec<ChatMessage>, CoreError> {
        Ok(self
            .inbox
            .messages_before(
                chat_id,
                before.map(|c| (c.timestamp_secs, c.seq)),
                i64::from(limit),
            )
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(ChatMessage::from)
            .collect())
    }

    /// Messages containing `text` in any chat, newest first, at most 100.
    /// Runs on this Mac only.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn search_messages(&self, text: &str) -> Result<Vec<SearchHit>, CoreError> {
        Ok(self
            .inbox
            .search(text, 100)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(|h| SearchHit {
                chat_id: h.chat,
                seq: h.seq,
                timestamp_secs: h.ts,
                body: h.body.unwrap_or_default(),
                from_me: h.from_me,
            })
            .collect())
    }

    /// The one chat the app may send to during development.
    #[must_use]
    pub fn sendable_chat_id(&self) -> String {
        self.sender.peer_chat()
    }

    /// The picture of message `seq`: the full image once downloaded, else
    /// the thumbnail that came with the message.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn picture(&self, chat_id: &str, seq: i64) -> Result<Option<MessagePicture>, CoreError> {
        Ok(self
            .attachments
            .picture(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .map(|p| MessagePicture {
                bytes: p.bytes,
                full: p.full,
            }))
    }

    /// Downloads message `seq`'s photo, video, audio, or document;
    /// `on_chats_changed` reports it stored. False when it failed (offline,
    /// or gone from WhatsApp's servers); it may be asked for again.
    pub async fn download_media(&self, chat_id: String, seq: i64) -> bool {
        let (store, client) = (Arc::clone(&self.attachments), Arc::clone(&self.client));
        let done = self
            .runtime
            .spawn(async move { store.download(&client, &chat_id, seq).await })
            .await;
        match done {
            Ok(Ok(_)) => true,
            Ok(Err(e)) => {
                log::info!("media not downloaded: {e:#}");
                false
            }
            Err(_) => false,
        }
    }

    /// Sends a message that failed again, from the start.
    ///
    /// # Errors
    /// `Storage` if it cannot be queued again.
    pub fn retry_message(&self, chat_id: &str, seq: i64) -> Result<(), CoreError> {
        let queued = self
            .inbox
            .retry_failed(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?;
        if queued {
            self.sender
                .listener
                .on_chats_changed(vec![chat_id.to_owned()]);
            let sender = Arc::clone(&self.sender);
            self.runtime.spawn(async move { sender.flush(false).await });
        }
        Ok(())
    }

    /// Message `seq`'s downloaded video, audio, or document, in memory; nil
    /// until `download_media` has stored it.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn media_file(&self, chat_id: &str, seq: i64) -> Result<Option<Vec<u8>>, CoreError> {
        Ok(self
            .attachments
            .file_of(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .map(|bytes| bytes.to_vec()))
    }

    /// The stored profile picture of a chat (JPEG), if any.
    ///
    /// # Errors
    /// `Storage` if the stored picture cannot be read.
    pub fn avatar(&self, chat_id: &str) -> Result<Option<Vec<u8>>, CoreError> {
        self.avatars
            .get(chat_id)
            .map_err(err(|detail| CoreError::Storage { detail }))
    }

    /// Fetches a chat's profile picture in the background unless it was
    /// checked in the last day; `on_chats_changed` reports a new one. Call it
    /// for chats on screen only.
    pub fn request_avatar(&self, chat_id: String) {
        let (avatars, client) = (Arc::clone(&self.avatars), Arc::clone(&self.client));
        self.runtime.spawn(async move {
            if let Err(e) = avatars.refresh(&client, &chat_id, unix_now()).await {
                log::info!("avatar not fetched: {e:#}");
            }
        });
    }

    /// Asks the linked phone (never a contact) for messages before the oldest
    /// one stored for `chat_id`; they arrive later as history. False when
    /// nothing is stored to anchor the request.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read or the chat id is malformed.
    pub fn request_older_history(&self, chat_id: &str) -> Result<bool, CoreError> {
        // WhatsApp Web asks for 50 at a time.
        const COUNT: i32 = 50;
        let Some((id, from_me, ts)) = self
            .inbox
            .oldest(chat_id)
            .map_err(err(|detail| CoreError::Storage { detail }))?
        else {
            return Ok(false);
        };
        let jid: Jid = chat_id.parse().map_err(|_| CoreError::Storage {
            detail: "not a chat id".into(),
        })?;
        let client = Arc::clone(&self.client);
        self.runtime.spawn(async move {
            // The phone answers later with a history chunk, imported like any
            // other; a phone that is offline simply never answers.
            match client
                .fetch_message_history(&jid, &id, from_me, ts * 1000, COUNT)
                .await
            {
                Ok(_) => log::info!("asked the phone for older history"),
                Err(e) => log::warn!("older history not requested: {e:#}"),
            }
        });
        Ok(true)
    }

    /// Marks the chat read here. Only the test chat also tells the sender
    /// (read receipts); every other chat stays read-only toward WhatsApp.
    ///
    /// # Errors
    /// `Storage` if the read state cannot be written.
    pub fn mark_chat_read(&self, chat_id: &str) -> Result<(), CoreError> {
        let read = self
            .inbox
            .mark_chat_read(chat_id)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        if read.is_empty() {
            return Ok(());
        }
        self.sender
            .listener
            .on_chats_changed(vec![chat_id.to_owned()]);
        if chat_id == self.sender.peer_chat() {
            let sender = Arc::clone(&self.sender);
            let ids: Vec<String> = read.into_iter().map(|u| u.id).collect();
            self.runtime
                .spawn(async move { sender.send_read_receipts(ids).await });
        }
        Ok(())
    }

    /// Reacts to message `seq` with `emoji`; an empty one removes it.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, more than one emoji, a
    /// message that is gone, or a failed send; `Storage` if it cannot be
    /// stored.
    pub async fn react(&self, chat_id: String, seq: i64, emoji: String) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.runtime
            .spawn(async move { sender.react(&chat_id, seq, &emoji).await })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }

    /// Mutes or unmutes a chat on every device of the account.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, or when WhatsApp does
    /// not take the change; `Storage` if it cannot be stored.
    pub async fn set_muted(&self, chat_id: String, muted: bool) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.runtime
            .spawn(async move { sender.set_muted(&chat_id, muted).await })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }

    /// Queues a photo or document and starts sending it, like `send_text`.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, an empty or too large
    /// file, a photo that is not JPEG, or a full queue; `Storage` if it
    /// cannot be queued.
    #[allow(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes records by value"
    )]
    pub fn send_file(&self, chat_id: &str, file: OutgoingFile) -> Result<(), CoreError> {
        self.sender.enqueue_file(chat_id, &file)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Queues a text message and starts sending it. Returns once it is
    /// stored; delivery state arrives through `on_chats_changed`.
    ///
    /// # Errors
    /// `reply_to` is the `seq` of the message being replied to.
    ///
    /// `SendRefused` for anything but the test chat, an empty or too long
    /// message, or a full queue; `Storage` if it cannot be queued.
    pub fn send_text(
        &self,
        chat_id: &str,
        text: &str,
        reply_to: Option<i64>,
    ) -> Result<(), CoreError> {
        self.sender.enqueue(chat_id, text, reply_to)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    #[must_use]
    pub fn state(&self) -> ConnectionState {
        self.machine.current()
    }

    /// Input from the app's network monitor. A restored path reconnects at
    /// once instead of waiting for upstream's backoff.
    pub fn network_changed(&self, available: bool) {
        self.machine.feed(if available {
            Input::NetworkRestored
        } else {
            Input::NetworkLost
        });
        if available {
            self.reconnect_now();
        }
    }

    /// Asks for an eight-character code to link by phone number instead of a
    /// QR scan. The code arrives through `CoreListener::on_pair_code`, or a
    /// failure through `on_pair_code_error`. Only meaningful while pairing.
    ///
    /// # Errors
    /// `phone_number` is not an international number.
    pub fn request_pair_code(&self, phone_number: &str) -> Result<(), CoreError> {
        let digits = Peer::parse(phone_number)
            .map_err(|_| CoreError::InvalidPhoneNumber)?
            .jid()
            .user
            .to_string();
        if let Ok(mut phone) = self.pair_phone.lock() {
            *phone = Some(digits.clone());
        }
        let client = Arc::clone(&self.client);
        self.runtime
            .spawn(async move { request_code(&client, digits).await });
        Ok(())
    }

    /// Drops the socket and reconnects without backoff, e.g. after wake from
    /// sleep, when the old socket is likely dead. Does nothing in a terminal
    /// state. Returns immediately.
    pub fn reconnect_now(&self) {
        if self.machine.current().is_terminal() {
            return;
        }
        let client = Arc::clone(&self.client);
        self.runtime
            .spawn(async move { client.reconnect_immediately().await });
    }

    /// Unlinks this Mac (when still linked), then destroys the Keychain key
    /// and all local data. Drop the core afterwards and start a new one to
    /// pair again. Blocks for up to the logout and shutdown timeouts.
    ///
    /// # Errors
    /// The key or local files could not be deleted. The session is stopped
    /// either way.
    pub fn log_out_and_reset(&self) -> Result<(), CoreError> {
        const LOGOUT: Duration = Duration::from_secs(10);
        if !self.machine.current().is_terminal() {
            let client = Arc::clone(&self.client);
            let report = self
                .runtime
                .block_on(async { tokio::time::timeout(LOGOUT, client.logout()).await });
            // Not fatal: the phone can still remove the device by hand.
            log::info!("logout sent: {}", report.is_ok());
        }
        self.stop();
        stores::reset(&self.dir).map_err(err(|detail| CoreError::Storage { detail }))?;
        log::info!("local data destroyed");
        // Let the next core in even if Swift still holds this one.
        drop(self.lock.lock().map(|mut l| l.take()));
        Ok(())
    }

    /// Disconnects, waiting at most a few seconds so quitting never hangs.
    /// Safe to call more than once.
    pub fn stop(&self) {
        const GRACE: Duration = Duration::from_secs(3);
        let handle = self.handle.lock().map_or(None, |mut h| h.take());
        if let Some(handle) = handle {
            let report = self
                .runtime
                .block_on(async { tokio::time::timeout(GRACE, handle.shutdown()).await });
            match report {
                Ok(report) => log::info!("core stopped: {report:?}"),
                Err(_) => log::warn!("core shutdown exceeded {GRACE:?}; exiting anyway"),
            }
        }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        self.stop();
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// Deletes disappearing messages when due, now and then every minute. Ends
/// with the runtime.
async fn purge_expired(inbox: Inbox, attachments: Arc<Attachments>) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    let mut round = 0_u64;
    loop {
        tick.tick().await;
        round = round.wrapping_add(1);
        // Images of messages that are gone: at start, then every 15 minutes
        // (deleted-by-sender messages are caught here too).
        if round % 15 == 1 {
            let store = Arc::clone(&attachments);
            match tokio::task::spawn_blocking(move || store.sweep()).await {
                Ok(Ok(0)) => {}
                Ok(Ok(n)) => log::info!("removed {n} image(s) of messages that are gone"),
                Ok(Err(e)) => log::warn!("images not swept: {e:#}"),
                Err(e) => log::warn!("sweep task failed: {e}"),
            }
        }
        let now = unix_now();
        let batch = inbox.clone();
        match tokio::task::spawn_blocking(move || batch.purge_expired(now)).await {
            Ok(Ok(chats)) if !chats.is_empty() => {
                log::info!("removed disappearing messages from {} chat(s)", chats.len());
                inbox.notify_changed(chats);
            }
            Ok(Ok(_)) => {}
            Ok(Err(e)) => log::warn!("expired messages not removed: {e:#}"),
            Err(e) => log::warn!("expiry task failed: {e}"),
        }
    }
}

#[derive(uniffi::Record)]
pub struct MessagePicture {
    pub bytes: Vec<u8>,
    /// False while only the thumbnail is stored.
    pub full: bool,
}

/// Position of a message in a chat's timeline.
#[derive(uniffi::Record)]
pub struct Cursor {
    pub timestamp_secs: i64,
    pub seq: i64,
}

struct Session {
    handle: BotHandle,
    client: Arc<Client>,
    lock: File,
    dir: PathBuf,
    inbox: Inbox,
    sender: Arc<outbox::Sender>,
    avatars: Arc<Avatars>,
    attachments: Arc<Attachments>,
}

async fn open_stores() -> Result<stores::Stores, CoreError> {
    stores::open(Fault::None).await.map_err(|e| {
        if e.downcast_ref::<AlreadyRunning>().is_some() {
            CoreError::AlreadyRunning
        } else {
            CoreError::Storage {
                detail: format!("{e:#}"),
            }
        }
    })
}

async fn connect(
    test_peer: &str,
    machine: Arc<Machine>,
    pair_phone: Arc<Mutex<Option<String>>>,
) -> Result<Session, CoreError> {
    let peer = Peer::parse(test_peer).map_err(err(|detail| CoreError::InvalidPeer { detail }))?;
    let mut stores = open_stores().await?;
    let listener = Arc::clone(&machine.listener);
    stores
        .inbox
        .set_on_commit(Arc::new(move |chats| listener.on_chats_changed(chats)));
    let inbox = stores.inbox.clone();
    let history_inbox = stores.inbox.clone();
    // Handlers are built before the client exists; they find the sender here.
    let sender_cell: Arc<OnceLock<Arc<outbox::Sender>>> = Arc::default();
    let sender_listener = Arc::clone(&machine.listener);
    let sender_machine = Arc::clone(&machine);
    let (on_qr, on_code, on_code_err) = (
        Arc::clone(&machine),
        Arc::clone(&machine),
        Arc::clone(&machine),
    );
    let avatars = Arc::new(Avatars::new(
        stores.inbox.clone(),
        stores.avatar_dir.clone(),
        stores.media_key.clone(),
    ));
    let attachments = Arc::new(Attachments::new(
        stores.inbox.clone(),
        stores.media_dir.clone(),
        stores.media_key.clone(),
    ));
    let bot = message_handlers(Bot::builder(), history_inbox, &sender_cell, &avatars)
        .with_backend(stores.protocol)
        .with_inbound_durability_hook(stores.inbox)
        .with_event_delivery(EVENT_DELIVERY)
        .on_qr_code(move |code, timeout| {
            on_qr.feed(Input::QrShown);
            on_qr.listener.on_qr(code, timeout.as_secs());
            async {}
        })
        .on_pair_code(move |code, timeout| {
            on_code.listener.on_pair_code(code, timeout.as_secs());
            async {}
        })
        .on_pair_code_error(move |e, _| {
            // Only the classification is logged; the message can echo the number.
            log::warn!("pair code refused: {:?}", e.rejection);
            on_code_err.listener.on_pair_code_error(
                e.rejection.is_some_and(PairCodeRejection::is_throttled),
                e.backoff.map(|d| d.as_secs()),
            );
            async {}
        })
        .on_pair_code_refresh(move |_, client| {
            let phone = pair_phone.lock().ok().and_then(|p| p.clone());
            async move {
                if let Some(phone) = phone {
                    request_code(&client, phone).await;
                }
            }
        })
        .on_event_for(
            &[
                EventKind::Connected,
                EventKind::Disconnected,
                EventKind::LoggedOut,
                EventKind::StreamReplaced,
                EventKind::TemporaryBan,
                EventKind::ClientOutdated,
                EventKind::ConnectFailure,
                EventKind::StreamError,
                EventKind::PairingQrCodesExhausted,
                EventKind::PairSuccess,
            ],
            move |event, _| {
                if let Some(input) = input_from(&event) {
                    machine.feed(input);
                }
                async {}
            },
        )
        .build()
        .await
        .map_err(err(|detail| CoreError::Startup { detail }))?;
    let client = bot.client();
    let sender = Arc::new(outbox::Sender::new(
        inbox.clone(),
        Arc::clone(&client),
        peer.jid(),
        sender_listener,
        Arc::clone(&attachments),
        Box::new(move || sender_machine.current() == ConnectionState::Connected),
    ));
    let _ = sender_cell.set(Arc::clone(&sender));
    Ok(Session {
        handle: bot.spawn(),
        client,
        lock: stores.lock,
        dir: stores.dir,
        inbox,
        sender,
        avatars,
        attachments,
    })
}

/// History import, delivery receipts, and outbox flushes on connect.
fn message_handlers<B, T, H, R>(
    builder: whatsapp_rust::bot::BotBuilder<B, T, H, R>,
    history_inbox: Inbox,
    sender_cell: &Arc<OnceLock<Arc<outbox::Sender>>>,
    avatars: &Arc<Avatars>,
) -> whatsapp_rust::bot::BotBuilder<B, T, H, R> {
    let (on_up, on_receipt) = (Arc::clone(sender_cell), Arc::clone(sender_cell));
    let (pictures, picture_inbox) = (Arc::clone(avatars), history_inbox.clone());
    builder
        .on_event_for(&[EventKind::PictureUpdate], move |event, client| {
            let (avatars, inbox) = (Arc::clone(&pictures), picture_inbox.clone());
            async move {
                let Event::PictureUpdate(update) = &*event else {
                    return;
                };
                log::info!("picture changed notification (removed: {})", update.removed);
                let chat = lids::phone_chat(&inbox, &client, &update.jid).await;
                // Fetch the new one now; refresh reports the change itself.
                if let Err(e) = avatars.invalidate(&chat) {
                    log::warn!("avatar not invalidated: {e:#}");
                }
                if let Err(e) = avatars.refresh(&client, &chat, unix_now()).await {
                    log::info!("avatar not fetched: {e:#}");
                }
            }
        })
        .on_event_for(&[EventKind::HistorySync], move |event, client| {
            let inbox = history_inbox.clone();
            async move {
                let Event::HistorySync(sync) = &*event else {
                    return;
                };
                let sync = (**sync).clone(); // shares the compressed bytes
                // Inflating and storing a chunk takes a while; keep it off
                // the protocol runtime.
                let importer = inbox.clone();
                match tokio::task::spawn_blocking(move || history::import(&importer, &sync)).await {
                    Ok(Ok(n)) => log::info!("history chunk stored: {n} message(s)"),
                    Ok(Err(e)) => log::warn!("history chunk not stored: {e:#}"),
                    Err(e) => log::warn!("history import panicked: {e}"),
                }
                // History teaches upstream LID numbers; merge what it learned.
                lids::resolve(&inbox, &client).await;
            }
        })
        .on_event_for(
            &[
                EventKind::Receipt,
                EventKind::ServerAck,
                EventKind::MarkChatAsReadUpdate,
                EventKind::ContactUpdate,
                EventKind::ContactRemoved,
                EventKind::DisappearingModeChanged,
                EventKind::AppStateSyncFailed,
                EventKind::MuteUpdate,
            ],
            move |event, _| {
                let sender = on_receipt.get().cloned();
                async move {
                    if let Some(sender) = sender {
                        on_account_event(sender, &event).await;
                    }
                }
            },
        )
        .on_connected(move |_| {
            // Messages queued while offline go out now.
            let sender = on_up.get().cloned();
            async move {
                if let Some(sender) = sender {
                    sender.connection_restarted();
                    sender.flush(true).await;
                    // Also cleans up chats stored by LID in earlier runs.
                    lids::resolve(&sender.inbox, &sender.client).await;
                    sender.load_contacts_once().await;
                    sender.load_mutes_once().await;
                }
            }
        })
}

/// Receipts and app-state changes synced from the account's other devices.
async fn on_account_event(sender: Arc<outbox::Sender>, event: &Event) {
    match event {
        Event::Receipt(receipt) => sender.on_receipt(receipt).await,
        Event::ServerAck(ack) => sender.on_server_ack(ack),
        Event::ContactUpdate(c) => {
            let a = &c.action;
            let name = a.full_name.as_deref().or(a.first_name.as_deref());
            sender
                .on_contact(&c.jid, name.unwrap_or(""), a.pn_jid.as_deref())
                .await;
        }
        Event::ContactRemoved(c) => sender.on_contact(&c.jid, "", None).await,
        // Collection names only, never their content.
        Event::AppStateSyncFailed(f) => log::warn!(
            "app state not synced: fatal {:?}, retryable {:?}, skipped {:?}",
            f.fatal,
            f.retryable,
            f.skipped
        ),
        Event::DisappearingModeChanged(d) => {
            log::info!("disappearing mode changed: {}s", d.duration);
            sender.on_timer(&d.from, d.duration).await;
        }
        Event::MuteUpdate(m) => {
            let a = &m.action;
            sender
                .on_mute(&m.jid, a.muted.unwrap_or(false), a.mute_end_timestamp)
                .await;
        }
        Event::MarkChatAsReadUpdate(update) => {
            let range = update.action.message_range.as_option();
            sender
                .on_chat_marked_read(
                    &update.jid,
                    update.action.read.unwrap_or(false),
                    range.and_then(|r| r.last_message_timestamp),
                )
                .await;
        }
        _ => {}
    }
}

/// The default 256-event mailbox drops the newest event when full, and the
/// address book arrives as thousands of contact events at once.
/// ponytail: a large fixed buffer; store contacts in a backend hook if an
/// address book ever outgrows it.
const EVENT_DELIVERY: whatsapp_rust::EventDelivery =
    whatsapp_rust::EventDelivery::BoundedConcurrent {
        capacity: 50_000,
        max_concurrency: 16,
    };

/// Failures are reported through the `PairingCodeError` event, so the
/// returned error carries nothing new.
async fn request_code(client: &Arc<Client>, phone_number: String) {
    let options = PairCodeOptions {
        phone_number,
        ..PairCodeOptions::default()
    };
    if client.pair_with_code(options).await.is_err() {
        log::warn!("pair code request failed");
    }
}

/// Maps the upstream events plan 10.1 names onto state machine inputs.
fn input_from(event: &Event) -> Option<Input> {
    Some(match event {
        // Linked. Upstream announces Connected only once the first history
        // sync is through, which after a fresh pairing can take minutes;
        // the session is live already and history fills in as it comes.
        Event::Connected(_) | Event::PairSuccess(_) => Input::Connected,
        Event::Disconnected(_) => Input::Disconnected,
        Event::LoggedOut(_) => Input::LoggedOut,
        Event::StreamReplaced(_) => Input::StreamReplaced,
        Event::TemporaryBan(ban) => Input::TemporaryBan {
            expires_in_secs: u64::try_from(ban.expire.num_seconds()).unwrap_or(0),
        },
        Event::ClientOutdated(_) => Input::ClientOutdated,
        Event::ConnectFailure(f) => Input::ConnectFailure {
            logged_out: f.reason.is_logged_out(),
            retry: f.reason.should_reconnect(),
            reason: format!("{:?}", f.reason),
        },
        Event::StreamError(e) => Input::StreamError {
            code: e.code.clone(),
        },
        Event::PairingQrCodesExhausted(_) => Input::QrExhausted,
        _ => return None,
    })
}

/// Sends NIMQO's own `log` records to the unified log (Console.app,
/// `/usr/bin/log stream`). `os_log` stores them as public, so upstream records
/// are dropped: they can carry JIDs, which are phone numbers.
fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        log::set_max_level(log::LevelFilter::Info);
        // Fails only if another logger is already installed; keep that one.
        let _ = log::set_boxed_logger(Box::new(NimqoOnly(oslog::OsLogger::new("app.nimqo.core"))));
    });
}

struct NimqoOnly(oslog::OsLogger);

impl log::Log for NimqoOnly {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        metadata.target().starts_with("nimqo") && metadata.level() <= log::Level::Info
    }

    fn log(&self, record: &log::Record<'_>) {
        if self.enabled(record.metadata()) {
            self.0.log(record);
        }
    }

    fn flush(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Silent;
    impl CoreListener for Silent {
        fn on_state(&self, _: ConnectionState) {}
        fn on_qr(&self, _: String, _: u64) {}
        fn on_pair_code(&self, _: String, _: u64) {}
        fn on_pair_code_error(&self, _: bool, _: Option<u64>) {}
        fn on_chats_changed(&self, _: Vec<String>) {}
    }

    #[test]
    fn only_nimqo_targets_reach_the_unified_log() {
        use log::Log;
        let logger = NimqoOnly(oslog::OsLogger::new("test"));
        let meta = |target| {
            log::Metadata::builder()
                .target(target)
                .level(log::Level::Info)
                .build()
        };
        assert!(logger.enabled(&meta("nimqo_ffi")));
        assert!(!logger.enabled(&meta("whatsapp_rust::client")));
    }

    #[test]
    fn invalid_peer_fails_before_touching_storage() {
        let e = Core::start("not a number", Arc::new(Silent)).err().unwrap();
        assert!(matches!(e, CoreError::InvalidPeer { .. }), "{e}");
    }
}
