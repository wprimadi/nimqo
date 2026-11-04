//! Opens the encrypted stores in the development data directory. Shared by
//! the CLI proof of concept and the app core.

use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use whatsapp_rust_sqlite_storage::{SqliteDatabase, SqliteDatabaseConfig, SqliteStore};

use crate::inbox::Inbox;
use crate::peer::Peer;
use crate::vault::{self, Key, MasterKey};

/// Development identity, separate from any future release build (plan 11.2).
const KEYCHAIN_SERVICE: &str = "dev.nimqo.poc";
const KEYCHAIN_ACCOUNT: &str = "master-key-v1";

pub struct Stores {
    pub dir: PathBuf,
    pub protocol: SqliteStore,
    pub inbox: Inbox,
    pub media_key: Key,
    pub media_dir: PathBuf,
}

/// Loads the Keychain master key and opens both databases with derived keys.
///
/// # Errors
/// The data directory, Keychain, or a database cannot be opened.
pub async fn open(peer: Peer, fail_commits: bool) -> Result<Stores> {
    let dir = data_dir()?;
    let master = MasterKey::load_or_create(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?;

    let protocol_db = dir.join("protocol.db");
    let url = protocol_db.to_str().context("data path is not UTF-8")?;
    let config = SqliteDatabaseConfig::default().with_connection_init(crate::db::connection_init(
        master.derive(vault::PROTOCOL_DB),
    ));
    let protocol = SqliteDatabase::open(url, config).await?.store(1);
    let inbox = Inbox::open(
        &dir.join("app.db"),
        &master.derive(vault::APP_DB),
        peer,
        fail_commits,
    )?;
    let media_dir = private_dir(&dir.join("media"))?;
    Ok(Stores {
        protocol,
        inbox,
        media_key: master.derive(vault::MEDIA),
        media_dir,
        dir,
    })
}

/// `~/Library/Application Support/NIMQO-dev`, readable only by this user.
fn data_dir() -> Result<PathBuf> {
    let home = std::env::home_dir().context("no home directory")?;
    // ponytail: no Time Machine exclusion yet (plan 11.2); the app sets it via
    // NSURL isExcludedFromBackup, a CLI would have to shell out to tmutil.
    private_dir(&home.join("Library/Application Support/NIMQO-dev"))
}

/// Creates `path` if needed and makes it owner-only.
///
/// # Errors
/// The directory cannot be created or its permissions set.
pub fn private_dir(path: &Path) -> Result<PathBuf> {
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o700))?;
    Ok(path.to_owned())
}
