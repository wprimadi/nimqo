//! UniFFI surface for the Swift app (plan section 8, ADR 0001).
//!
//! The app only pairs and reports connection status in Phase 0. It sends no
//! messages; the durability hook still stores the allowlisted peer's
//! messages, so nothing is acknowledged without being kept.

use std::sync::{Arc, Mutex};

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

#[derive(Debug, uniffi::Error)]
#[uniffi(flat_error)]
pub enum CoreError {
    Failed(String),
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Failed(msg) = self;
        f.write_str(msg)
    }
}

impl From<anyhow::Error> for CoreError {
    fn from(e: anyhow::Error) -> Self {
        Self::Failed(format!("{e:#}"))
    }
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
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| CoreError::Failed(e.to_string()))?;
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

async fn connect(test_peer: &str, listener: Arc<dyn CoreListener>) -> anyhow::Result<BotHandle> {
    let stores = stores::open(Peer::parse(test_peer)?, false).await?;
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
        .await?;
    Ok(bot.spawn())
}
