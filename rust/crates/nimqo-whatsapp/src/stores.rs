//! Opens the encrypted stores in the development data directory. Shared by
//! the CLI proof of concept and the app core.

use std::fs::{File, TryLockError};
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use whatsapp_rust_sqlite_storage::{SqliteDatabase, SqliteDatabaseConfig, SqliteStore};

use crate::inbox::{Fault, Inbox};
use crate::vault::{self, Key, MasterKey};

/// Development identity, separate from any future release build (plan 11.2).
const KEYCHAIN_SERVICE: &str = "dev.nimqo.poc";
const KEYCHAIN_ACCOUNT: &str = "master-key-v1";

pub struct Stores {
    /// Held for the life of the session; dropping it lets another process in.
    pub lock: File,
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
pub async fn open(fault: Fault) -> Result<Stores> {
    let dir = data_dir()?;
    let lock = lock_dir(&dir)?;
    let master = MasterKey::load_or_create(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?;

    let protocol_db = dir.join("protocol.db");
    let url = protocol_db.to_str().context("data path is not UTF-8")?;
    let config = SqliteDatabaseConfig::default().with_connection_init(crate::db::connection_init(
        master.derive(vault::PROTOCOL_DB),
    ));
    let protocol = SqliteDatabase::open(url, config).await?.store(1);
    let inbox = Inbox::open(&dir.join("app.db"), &master.derive(vault::APP_DB), fault)?;
    let media_dir = private_dir(&dir.join("media"))?;
    Ok(Stores {
        lock,
        protocol,
        inbox,
        media_key: master.derive(vault::MEDIA),
        media_dir,
        dir,
    })
}

/// Destroys the session and all local data: the Keychain key first, so
/// anything a failed delete leaves behind is already unreadable, then every
/// file except the lock, which the caller still holds.
///
/// # Errors
/// The Keychain key or a file cannot be deleted.
pub fn reset(dir: &Path) -> Result<()> {
    vault::destroy(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?;
    clear_dir(dir)
}

fn clear_dir(dir: &Path) -> Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let path = entry?.path();
        if path.file_name() == Some(".lock".as_ref()) {
            continue;
        }
        if path.is_dir() {
            std::fs::remove_dir_all(&path)?;
        } else {
            std::fs::remove_file(&path)?;
        }
    }
    Ok(())
}

/// Another NIMQO process (app or CLI) holds the data directory.
#[derive(Debug)]
pub struct AlreadyRunning;

impl std::fmt::Display for AlreadyRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("another NIMQO process is using this data directory")
    }
}

impl std::error::Error for AlreadyRunning {}

/// Takes an exclusive lock so two processes never open the same session
/// databases (plan 7.6). The OS releases it if the process dies.
///
/// # Errors
/// [`AlreadyRunning`] if another process holds it, or an I/O error.
pub fn lock_dir(dir: &Path) -> Result<File> {
    let file = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(dir.join(".lock"))?;
    match file.try_lock() {
        Ok(()) => Ok(file),
        Err(TryLockError::WouldBlock) => Err(AlreadyRunning.into()),
        Err(TryLockError::Error(e)) => Err(e.into()),
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn second_lock_is_refused_until_the_first_is_dropped() {
        let dir = std::env::temp_dir().join(format!("nimqo-lock-{}", std::process::id()));
        private_dir(&dir).unwrap();
        let first = lock_dir(&dir).unwrap();
        let err = lock_dir(&dir).unwrap_err();
        assert!(err.downcast_ref::<AlreadyRunning>().is_some(), "{err}");
        drop(first);
        lock_dir(&dir).unwrap();
    }

    #[test]
    fn clearing_keeps_only_the_lock() {
        let dir = std::env::temp_dir().join(format!("nimqo-clear-{}", std::process::id()));
        private_dir(&dir.join("media")).unwrap();
        let _lock = lock_dir(&dir).unwrap();
        std::fs::write(dir.join("app.db"), b"x").unwrap();
        std::fs::write(dir.join("media/a.nqm"), b"x").unwrap();
        clear_dir(&dir).unwrap();
        let left: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name())
            .collect();
        assert_eq!(left, [".lock"]);
    }
}
