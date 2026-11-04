//! Phase 0 proof of concept: pair, persist an encrypted session, and exchange
//! text with ONE allowlisted test number, typed by hand.
//!
//! ```sh
//! NIMQO_TEST_PEER=+62... cargo run --bin nimqo-poc
//! ```
//!
//! Safety for real accounts: it never auto-replies, never sends read
//! receipts, never sends to anyone but the peer, and rate-limits sends.

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use log::{error, info, warn};
use nimqo_whatsapp::inbox::Inbox;
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::vault::{self, MasterKey};
use qrcode::QrCode;
use qrcode::render::svg;
use tokio::io::{AsyncBufReadExt, BufReader};
use whatsapp_rust::prelude::*;
use whatsapp_rust_sqlite_storage::{SqliteDatabase, SqliteDatabaseConfig};

/// Minimum spacing between sends; a guard against accidental bursts.
const SEND_INTERVAL: Duration = Duration::from_secs(3);
const MAX_TEXT_LEN: usize = 1000;
/// Development identity, separate from any future release build (plan 11.2).
const KEYCHAIN_SERVICE: &str = "dev.nimqo.poc";
const KEYCHAIN_ACCOUNT: &str = "master-key-v1";

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    let peer_number = std::env::var("NIMQO_TEST_PEER")
        .context("set NIMQO_TEST_PEER to the only number this tool may talk to")?;
    tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?
        .block_on(run(&peer_number))
}

async fn run(peer_number: &str) -> Result<()> {
    let dir = data_dir()?;
    let master = MasterKey::load_or_create(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?;

    let protocol_db = dir.join("protocol.db");
    let url = protocol_db.to_str().context("data path is not UTF-8")?;
    let config = SqliteDatabaseConfig::default().with_connection_init(
        nimqo_whatsapp::db::connection_init(master.derive(vault::PROTOCOL_DB)),
    );
    let store = SqliteDatabase::open(url, config).await?.store(1);

    let fail_commits = std::env::var_os("NIMQO_FAIL_COMMIT").is_some();
    if fail_commits {
        warn!("NIMQO_FAIL_COMMIT set: no message will be acknowledged this run");
    }
    let inbox = Inbox::open(
        &dir.join("app.db"),
        &master.derive(vault::APP_DB),
        Peer::parse(peer_number)?,
        fail_commits,
    )?;
    info!(
        "encrypted stores ready; {} stored peer message(s)",
        inbox.count()?
    );
    drop(master);

    let filter = Peer::parse(peer_number)?;
    let qr_page = dir.join("pair-qr.html");
    let (qr_for_code, qr_for_connect) = (qr_page.clone(), qr_page.clone());
    let bot = Bot::builder()
        .with_backend(store)
        .with_inbound_durability_hook(inbox)
        .on_qr_code(move |code, timeout| {
            let page = qr_for_code.clone();
            async move {
                if let Err(e) = show_qr(&page, &code, timeout) {
                    error!("cannot show QR code: {e}");
                }
            }
        })
        .on_connected(move |_| {
            let page = qr_for_connect.clone();
            async move {
                // Replace the pairing secret with a plain notice for the open tab.
                let _ = write_private(&page, &html_page("Connected. You can close this tab."));
                info!("connected; type a line to send it to the test peer");
            }
        })
        .on_logged_out(|_| async { error!("logged out: device was unlinked") })
        .on_message(move |ctx| {
            let shown = filter.matches(&ctx.info.source).then(|| {
                ctx.message
                    .text_content()
                    .unwrap_or("<non-text>")
                    .to_owned()
            });
            async move {
                if let Some(text) = shown {
                    println!("< {text}");
                }
            }
        })
        .build()
        .await?;

    let client = bot.client();
    let mut handle = bot.spawn();
    let to = Peer::parse(peer_number)?.jid();
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    let mut last_send: Option<Instant> = None;

    loop {
        tokio::select! {
            _ = &mut handle => break,
            _ = tokio::signal::ctrl_c() => break,
            line = lines.next_line() => {
                let Some(line) = line? else { break };
                let text = line.trim();
                if text.is_empty() {
                    continue;
                }
                if text.chars().count() > MAX_TEXT_LEN {
                    warn!("not sent: longer than {MAX_TEXT_LEN} characters");
                    continue;
                }
                if let Some(wait) = last_send.and_then(|t| SEND_INTERVAL.checked_sub(t.elapsed())) {
                    warn!("not sent: wait {}s between messages", wait.as_secs() + 1);
                    continue;
                }
                last_send = Some(Instant::now());
                match client.send_message(to.clone(), wa::Message::text(text)).await {
                    Ok(sent) => info!("> sent {}", sent.message_id),
                    Err(e) => error!("send failed: {e}"),
                }
            }
        }
    }
    info!("shutting down: {:?}", handle.shutdown().await);
    let _ = std::fs::remove_file(&qr_page);
    Ok(())
}

/// Renders the QR as SVG in a self-refreshing local page and opens it once.
/// Terminal block rendering proved unscannable (inverted colors on dark
/// themes, line spacing gaps), so the browser draws it instead.
fn show_qr(page: &Path, code: &str, timeout: Duration) -> Result<()> {
    static OPENED: AtomicBool = AtomicBool::new(false);
    let svg = QrCode::new(code.as_bytes())
        .map_err(|e| anyhow::anyhow!("{e}"))?
        .render::<svg::Color>()
        .min_dimensions(360, 360)
        .build();
    let body = format!(
        "{svg}<p>Scan within {}s: WhatsApp &gt; Linked devices &gt; Link a device</p>",
        timeout.as_secs()
    );
    write_private(page, &html_page(&body))?;
    if !OPENED.swap(true, Ordering::Relaxed) {
        std::process::Command::new("open").arg(page).status()?;
    }
    info!("QR code shown in your browser (refreshes automatically)");
    Ok(())
}

fn html_page(body: &str) -> String {
    format!(
        "<!doctype html><meta charset=utf-8><meta http-equiv=refresh content=2>\
         <title>NIMQO pairing</title><body style=\"background:#fff;color:#000;\
         display:grid;place-items:center;height:100vh;margin:0;font:16px system-ui\">\
         <div style=text-align:center>{body}</div>"
    )
}

/// Owner-only file, replaced atomically so a refresh never reads half a page.
fn write_private(path: &Path, contents: &str) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(contents.as_bytes())?;
    drop(f);
    std::fs::rename(&tmp, path)?;
    Ok(())
}

/// `~/Library/Application Support/NIMQO-dev`, readable only by this user.
fn data_dir() -> Result<PathBuf> {
    let Some(home) = std::env::home_dir() else {
        bail!("no home directory")
    };
    let dir = home.join("Library/Application Support/NIMQO-dev");
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    // ponytail: no Time Machine exclusion yet (plan 11.2); the app sets it via
    // NSURL isExcludedFromBackup, a CLI would have to shell out to tmutil.
    Ok(dir)
}
