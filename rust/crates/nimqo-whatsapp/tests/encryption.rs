//! Encryption-at-rest checks from plan 11.3. No account or Keychain needed.

use std::path::{Path, PathBuf};

use diesel::{Connection, RunQueryDsl, SqliteConnection};
use nimqo_whatsapp::db::apply_key;
use nimqo_whatsapp::vault::{APP_DB, MasterKey, PROTOCOL_DB};
use zeroize::Zeroizing;

#[derive(diesel::QueryableByName)]
struct Row {
    #[diesel(sql_type = diesel::sql_types::Text)]
    body: String,
}

const MARKER: &str = "nimqo-plaintext-marker-6f1c";

fn temp_db(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("nimqo-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("test.db")
}

fn open(path: &Path, key: &[u8; 32]) -> Result<SqliteConnection, String> {
    let mut conn =
        SqliteConnection::establish(path.to_str().unwrap()).map_err(|e| e.to_string())?;
    apply_key(&mut conn, key).map_err(|e| e.to_string())?;
    Ok(conn)
}

#[test]
fn data_on_disk_is_encrypted_and_fails_closed() {
    let master = MasterKey::from_bytes(Zeroizing::new([42u8; 32]));
    let key = master.derive(APP_DB);
    let path = temp_db("enc");

    {
        let mut conn = open(&path, &key).unwrap();
        diesel::sql_query("PRAGMA journal_mode = WAL")
            .execute(&mut conn)
            .unwrap();
        diesel::sql_query("CREATE TABLE t (body TEXT)")
            .execute(&mut conn)
            .unwrap();
        diesel::sql_query(format!("INSERT INTO t VALUES ('{MARKER}')"))
            .execute(&mut conn)
            .unwrap();
        // Scan while the WAL still holds the write, then again after closing.
        assert_no_plaintext(&path);
    }
    assert_no_plaintext(&path);

    let header = std::fs::read(&path).unwrap();
    assert!(
        !header.starts_with(b"SQLite format 3"),
        "database header is plaintext"
    );

    let wrong = master.derive(PROTOCOL_DB);
    assert!(open(&path, &wrong).is_err(), "wrong key must fail closed");

    let mut conn = open(&path, &key).unwrap();
    let rows: Vec<Row> = diesel::sql_query("SELECT body FROM t")
        .load(&mut conn)
        .unwrap();
    assert_eq!(rows[0].body, MARKER);
}

fn assert_no_plaintext(path: &Path) {
    for entry in std::fs::read_dir(path.parent().unwrap()).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        assert!(
            !bytes.windows(MARKER.len()).any(|w| w == MARKER.as_bytes()),
            "plaintext found on disk"
        );
    }
}
