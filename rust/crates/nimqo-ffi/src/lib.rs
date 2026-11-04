//! UniFFI surface for the Swift app (plan section 8, ADR 0001).
//!
//! The app pairs and reports connection state. It sends no messages yet; the
//! durability hook still stores the allowlisted peer's messages, so nothing
//! is acknowledged without being kept.

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use nimqo_whatsapp::inbox::{Fault, Inbox};
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::stores::{self, AlreadyRunning};
use whatsapp_rust::Client;
use whatsapp_rust::bot::BotHandle;
use whatsapp_rust::pair_code::{PairCodeOptions, PairCodeRejection};
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{Event, EventKind};

uniffi::setup_scaffolding!();

mod chats;
mod state;

pub use chats::{Chat, ChatMessage, MessageKind};

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
        let (handle, client, (lock, dir, inbox)) = runtime.block_on(connect(
            test_peer,
            Arc::clone(&machine),
            Arc::clone(&pair_phone),
        ))?;
        Ok(Arc::new(Self {
            runtime,
            handle: Mutex::new(Some(handle)),
            client,
            machine,
            pair_phone,
            dir,
            inbox,
            lock: Mutex::new(Some(lock)),
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
    pub fn messages(&self, chat_id: &str) -> Result<Vec<ChatMessage>, CoreError> {
        const LIMIT: i64 = 200;
        Ok(self
            .inbox
            .messages(chat_id, LIMIT)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(ChatMessage::from)
            .collect())
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

async fn connect(
    test_peer: &str,
    machine: Arc<Machine>,
    pair_phone: Arc<Mutex<Option<String>>>,
) -> Result<(BotHandle, Arc<Client>, (File, PathBuf, Inbox)), CoreError> {
    // Validated now; sending to it comes with the composer.
    Peer::parse(test_peer).map_err(err(|detail| CoreError::InvalidPeer { detail }))?;
    let mut stores = stores::open(Fault::None).await.map_err(|e| {
        if e.downcast_ref::<AlreadyRunning>().is_some() {
            CoreError::AlreadyRunning
        } else {
            CoreError::Storage {
                detail: format!("{e:#}"),
            }
        }
    })?;
    let listener = Arc::clone(&machine.listener);
    stores
        .inbox
        .set_on_commit(Arc::new(move |chats| listener.on_chats_changed(chats)));
    let inbox = stores.inbox.clone();
    let (on_qr, on_code, on_code_err) = (
        Arc::clone(&machine),
        Arc::clone(&machine),
        Arc::clone(&machine),
    );
    let bot = Bot::builder()
        .with_backend(stores.protocol)
        .with_inbound_durability_hook(stores.inbox)
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
    Ok((bot.spawn(), client, (stores.lock, stores.dir, inbox)))
}

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
        Event::Connected(_) => Input::Connected,
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
