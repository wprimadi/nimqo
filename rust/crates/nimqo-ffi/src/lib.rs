//! UniFFI surface for the Swift app (plan section 8, ADR 0001).
//!
//! The app only pairs and reports connection status in Phase 0. It sends no
//! messages; the durability hook still stores the allowlisted peer's
//! messages, so nothing is acknowledged without being kept.

use std::sync::{Arc, Mutex};

use nimqo_whatsapp::inbox::Fault;
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::stores;
use whatsapp_rust::bot::BotHandle;
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::EventKind;

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionStatus {
    Connecting,
    WaitingForScan,
    Connected,
    Disconnected,
    LoggedOut,
}

/// Implemented in Swift. Called from Rust worker threads.
#[uniffi::export(with_foreign)]
pub trait CoreListener: Send + Sync {
    fn on_status(&self, status: ConnectionStatus);
    /// Raw pairing payload; the app renders it as a QR code.
    fn on_qr(&self, code: String, timeout_secs: u64);
}

/// Grouped by what the user can do about it. `detail` is for logs and bug
/// reports; it never contains message content.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum CoreError {
    /// The configured test number is not an international number.
    InvalidPeer { detail: String },
    /// The Keychain key or an encrypted database is unavailable. NIMQO fails
    /// closed here and never falls back to plaintext.
    Storage { detail: String },
    /// The client could not be built or started.
    Startup { detail: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (kind, detail) = match self {
            Self::InvalidPeer { detail } => ("invalid test number", detail),
            Self::Storage { detail } => ("encrypted storage unavailable", detail),
            Self::Startup { detail } => ("cannot start", detail),
        };
        write!(f, "{kind}: {detail}")
    }
}

impl std::error::Error for CoreError {}

fn err<E: std::fmt::Display>(make: fn(String) -> CoreError) -> impl Fn(E) -> CoreError {
    move |e| make(format!("{e:#}"))
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: tokio::runtime::Runtime,
    handle: Mutex<Option<BotHandle>>,
}

#[uniffi::export]
impl Core {
    /// Opens the encrypted stores and connects. Blocks until the connection
    /// task is running, so call it off the main thread.
    ///
    /// # Errors
    /// The peer number is invalid, or the stores or client cannot start.
    #[uniffi::constructor]
    pub fn start(test_peer: &str, listener: Arc<dyn CoreListener>) -> Result<Arc<Self>, CoreError> {
        init_logging();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| CoreError::Startup {
                detail: e.to_string(),
            })?;
        listener.on_status(ConnectionStatus::Connecting);
        let handle = runtime.block_on(connect(test_peer, listener))?;
        Ok(Arc::new(Self {
            runtime,
            handle: Mutex::new(Some(handle)),
        }))
    }

    /// Disconnects. Safe to call more than once.
    pub fn stop(&self) {
        let handle = self.handle.lock().map_or(None, |mut h| h.take());
        if let Some(handle) = handle {
            log::info!(
                "core stopped: {:?}",
                self.runtime.block_on(handle.shutdown())
            );
        }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn connect(test_peer: &str, listener: Arc<dyn CoreListener>) -> Result<BotHandle, CoreError> {
    let peer = Peer::parse(test_peer).map_err(err(|detail| CoreError::InvalidPeer { detail }))?;
    let stores = stores::open(peer, Fault::None)
        .await
        .map_err(err(|detail| CoreError::Storage { detail }))?;
    let (on_qr, on_up, on_down, on_out) = (
        Arc::clone(&listener),
        Arc::clone(&listener),
        Arc::clone(&listener),
        listener,
    );
    let bot = Bot::builder()
        .with_backend(stores.protocol)
        .with_inbound_durability_hook(stores.inbox)
        .on_qr_code(move |code, timeout| {
            on_qr.on_status(ConnectionStatus::WaitingForScan);
            on_qr.on_qr(code, timeout.as_secs());
            async {}
        })
        .on_connected(move |_| {
            on_up.on_status(ConnectionStatus::Connected);
            async {}
        })
        .on_event_for(&[EventKind::Disconnected], move |_, _| {
            on_down.on_status(ConnectionStatus::Disconnected);
            async {}
        })
        .on_logged_out(move |_| {
            on_out.on_status(ConnectionStatus::LoggedOut);
            async {}
        })
        .build()
        .await
        .map_err(err(|detail| CoreError::Startup { detail }))?;
    Ok(bot.spawn())
}

/// Sends Rust `log` records to the unified log (Console.app, `log stream`).
fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        // Fails only if another logger is already installed; keep that one.
        let _ = oslog::OsLogger::new("app.nimqo.core")
            .level_filter(log::LevelFilter::Info)
            .init();
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Silent;
    impl CoreListener for Silent {
        fn on_status(&self, _: ConnectionStatus) {}
        fn on_qr(&self, _: String, _: u64) {}
    }

    #[test]
    fn invalid_peer_fails_before_touching_storage() {
        let e = Core::start("not a number", Arc::new(Silent)).err().unwrap();
        assert!(matches!(e, CoreError::InvalidPeer { .. }), "{e}");
    }
}
