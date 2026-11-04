//! Phase 0 proof of concept: pair, persist an encrypted session, and exchange
//! text with ONE allowlisted test number, typed by hand.
//!
//! ```sh
//! NIMQO_TEST_PEER=+62... cargo run --bin nimqo-poc
//! ```
//!
//! Type a line to send it. `/img <path>` sends a JPEG or PNG; `/show <id>`
//! opens a received image (decrypted into the data dir until exit).
//!
//! Safety for real accounts: it never auto-replies, never sends read
//! receipts, never sends to anyone but the peer, and rate-limits sends.

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use log::{error, info, warn};
use nimqo_whatsapp::inbox::Inbox;
use nimqo_whatsapp::media;
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::vault::{self, Key, MasterKey};
use qrcode::QrCode;
use qrcode::render::svg;
use tokio::io::{AsyncBufReadExt, BufReader};
use whatsapp_rust::download::DownloadLimits;
use whatsapp_rust::media::{ImageOptions, image_message};
use whatsapp_rust::prelude::*;
use whatsapp_rust::wacore::download::MediaType;
use whatsapp_rust::{Client, UploadOptions};
use whatsapp_rust_sqlite_storage::{SqliteDatabase, SqliteDatabaseConfig};

/// Minimum spacing between sends; a guard against accidental bursts.
const SEND_INTERVAL: Duration = Duration::from_secs(3);
const MAX_TEXT_LEN: usize = 1000;
/// Caps both directions; WhatsApp itself limits images to 16 MiB.
const MAX_MEDIA_BYTES: u64 = 16 * 1024 * 1024;
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
    let media_key = Arc::new(master.derive(vault::MEDIA));
    drop(master);
    let media_dir = dir.join("media");
    let view_dir = dir.join("view");
    for d in [&media_dir, &view_dir] {
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(d)?;
    }

    let filter = Peer::parse(peer_number)?;
    let (rx_key, rx_dir) = (Arc::clone(&media_key), media_dir.clone());
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
                let _ = write_private(
                    &page,
                    html_page("Connected. You can close this tab.").as_bytes(),
                );
                info!("connected; type a line to send it to the test peer");
            }
        })
        .on_logged_out(|_| async { error!("logged out: device was unlinked") })
        .on_message(move |ctx| {
            let ours = filter.matches(&ctx.info.source);
            let (key, dir) = (Arc::clone(&rx_key), rx_dir.clone());
            async move {
                if ours {
                    show_incoming(&ctx, &key, &dir).await;
                }
            }
        })
        .build()
        .await?;

    let client = bot.client();
    let mut handle = bot.spawn();
    let mut session = Session {
        client,
        to: Peer::parse(peer_number)?.jid(),
        media_key,
        media_dir,
        view_dir: view_dir.clone(),
        last_send: None,
    };
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    loop {
        tokio::select! {
            _ = &mut handle => break,
            _ = tokio::signal::ctrl_c() => break,
            line = lines.next_line() => match line? {
                Some(line) => session.handle(line.trim()).await,
                None => break,
            },
        }
    }
    info!("shutting down: {:?}", handle.shutdown().await);
    let _ = std::fs::remove_file(&qr_page);
    let _ = std::fs::remove_dir_all(&view_dir);
    Ok(())
}

/// Typed input. Everything that reaches the network goes to `to` only.
struct Session {
    client: Arc<Client>,
    to: Jid,
    media_key: Arc<Key>,
    media_dir: PathBuf,
    view_dir: PathBuf,
    last_send: Option<Instant>,
}

impl Session {
    async fn handle(&mut self, text: &str) {
        if text.is_empty() {
            return;
        }
        if let Some(id) = text.strip_prefix("/show ") {
            if let Err(e) = show_image(&self.media_key, &self.media_dir, &self.view_dir, id.trim())
            {
                error!("cannot show image: {e:#}");
            }
            return;
        }
        if text.chars().count() > MAX_TEXT_LEN {
            warn!("not sent: longer than {MAX_TEXT_LEN} characters");
            return;
        }
        if let Some(wait) = self
            .last_send
            .and_then(|t| SEND_INTERVAL.checked_sub(t.elapsed()))
        {
            warn!("not sent: wait {}s between messages", wait.as_secs() + 1);
            return;
        }
        let message = match text.strip_prefix("/img ") {
            Some(path) => match upload_image(&self.client, Path::new(path.trim())).await {
                Ok(m) => m,
                Err(e) => return error!("image not sent: {e:#}"),
            },
            None => wa::Message::text(text),
        };
        self.last_send = Some(Instant::now());
        match self.client.send_message(self.to.clone(), message).await {
            Ok(sent) => info!("> sent {}", sent.message_id),
            Err(e) => error!("send failed: {e}"),
        }
    }
}

async fn show_incoming(ctx: &MessageContext, key: &Key, dir: &Path) {
    let Some(img) = ctx.message.get_base_message().image_message.as_option() else {
        println!(
            "< {}",
            ctx.message.text_content().unwrap_or("<unsupported>")
        );
        return;
    };
    match save_image(&ctx.client, img, key, dir, &ctx.info.id).await {
        Ok(id) => println!(
            "< [image saved; /show {id}] {}",
            img.caption.as_deref().unwrap_or("")
        ),
        Err(e) => error!("image not saved: {e:#}"),
    }
}

/// Downloads an incoming image (upstream verifies its hashes) and stores it
/// encrypted. Returns the file id for `/show`.
async fn save_image(
    client: &Client,
    img: &wa::message::ImageMessage,
    key: &Key,
    dir: &Path,
    msg_id: &str,
) -> Result<String> {
    // The id comes from the network; keep only safe filename characters.
    let id: String = msg_id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .take(64)
        .collect();
    anyhow::ensure!(!id.is_empty(), "message id has no usable characters");
    let plain = zeroize::Zeroizing::new(
        client
            .download(
                img,
                DownloadLimits::new(MAX_MEDIA_BYTES + 1024, MAX_MEDIA_BYTES),
            )
            .await?,
    );
    write_private(
        &dir.join(format!("{id}.nqm")),
        &media::encrypt(key, &plain)?,
    )?;
    Ok(id)
}

async fn upload_image(client: &Client, path: &Path) -> Result<wa::Message> {
    let mimetype = match path
        .extension()
        .and_then(|e| e.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("png") => "image/png",
        _ => bail!("only .jpg, .jpeg, and .png are supported"),
    };
    anyhow::ensure!(
        std::fs::metadata(path)?.len() <= MAX_MEDIA_BYTES,
        "larger than 16 MiB"
    );
    let upload = client
        .upload(std::fs::read(path)?, MediaType::Image, UploadOptions::new())
        .await?;
    Ok(image_message(
        upload,
        ImageOptions::default().with_mimetype(mimetype),
    ))
}

/// Decrypts into the owner-only view dir, removed when the tool exits.
fn show_image(key: &Key, media_dir: &Path, view_dir: &Path, id: &str) -> Result<()> {
    anyhow::ensure!(id.chars().all(|c| c.is_ascii_alphanumeric()), "invalid id");
    let plain = media::decrypt(key, &std::fs::read(media_dir.join(format!("{id}.nqm")))?)?;
    let view = view_dir.join(id);
    write_private(&view, &plain)?;
    std::process::Command::new("open")
        .args(["-a", "Preview"])
        .arg(&view)
        .status()?;
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
    write_private(page, html_page(&body).as_bytes())?;
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
fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(contents)?;
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
