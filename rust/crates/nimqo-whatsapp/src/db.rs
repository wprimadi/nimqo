//! SQLCipher keying (plan 11.3).
//!
//! Every connection is keyed before any other statement, then verified. If
//! the linked SQLite is not SQLCipher, `PRAGMA key` would be silently ignored
//! and data written in plaintext, so the cipher version is checked as well.

use std::error::Error;

use diesel::sql_types::Text;
use diesel::{QueryableByName, RunQueryDsl, SqliteConnection};
use zeroize::Zeroizing;

use crate::vault::Key;

type InitError = Box<dyn Error + Send + Sync>;

#[derive(QueryableByName)]
struct CipherVersion {
    #[diesel(sql_type = Text)]
    cipher_version: String,
}

/// Keys and verifies a fresh connection. Must be the first use of `conn`.
///
/// # Errors
/// SQLCipher is not linked, or the key does not open this database.
pub fn apply_key(conn: &mut SqliteConnection, key: &[u8; 32]) -> Result<(), InitError> {
    diesel::sql_query(key_pragma(key).as_str()).execute(conn)?;
    let version: Vec<CipherVersion> = diesel::sql_query("PRAGMA cipher_version").load(conn)?;
    if version.first().is_none_or(|v| v.cipher_version.is_empty()) {
        return Err("SQLCipher is not linked; refusing to write plaintext".into());
    }
    // Fails on a wrongly keyed database ("file is not a database").
    diesel::sql_query("SELECT count(*) FROM sqlite_master").execute(conn)?;
    Ok(())
}

/// Connection hook for upstream's `SqliteDatabaseConfig::with_connection_init`.
pub fn connection_init(
    key: Key,
) -> impl Fn(&mut SqliteConnection) -> Result<(), InitError> + Send + Sync + 'static {
    move |conn| apply_key(conn, &key)
}

/// `PRAGMA key` in SQLCipher's raw-key form, which skips passphrase derivation.
fn key_pragma(key: &[u8; 32]) -> Zeroizing<String> {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = Zeroizing::new(String::with_capacity(80));
    s.push_str("PRAGMA key = \"x'");
    for b in key {
        s.push(HEX[usize::from(b >> 4)].into());
        s.push(HEX[usize::from(b & 0xf)].into());
    }
    s.push_str("'\"");
    s
}

#[cfg(test)]
mod tests {
    use super::key_pragma;

    #[test]
    fn raw_key_pragma_format() {
        let mut key = [0u8; 32];
        key[0] = 0xab;
        key[31] = 0x01;
        let p = key_pragma(&key);
        assert!(p.starts_with("PRAGMA key = \"x'ab00"));
        assert!(p.ends_with("0001'\""));
        assert_eq!(p.len(), "PRAGMA key = \"x'".len() + 64 + 2);
    }
}
