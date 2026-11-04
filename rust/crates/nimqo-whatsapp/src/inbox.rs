//! Encrypted message store behind upstream's `InboundDurabilityHook`.
//!
//! Upstream acknowledges a message as soon as it is decrypted unless a
//! durability hook is registered. With this hook, a message is acknowledged
//! only after it is committed here; a failed or interrupted commit leaves it
//! on the server for redelivery (plan 10.4).

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use diesel::sql_types::{BigInt, Text};
use diesel::{Connection, RunQueryDsl, SqliteConnection};
use whatsapp_rust::prelude::MessageExt;
use whatsapp_rust::types::durability_hook::InboundMessage;
use whatsapp_rust::{Client, InboundDurabilityHook};

use crate::peer::Peer;
use crate::vault::Key;

/// Fault injection for redelivery tests. Always `None` outside tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    None,
    /// Refuse every commit.
    RefuseCommits,
    /// Wait before committing, leaving time to `kill -9` the process.
    DelayCommits(Duration),
}

pub struct Inbox {
    conn: Arc<Mutex<SqliteConnection>>,
    peer: Peer,
    fault: Fault,
}

impl Inbox {
    /// Opens (or creates) the encrypted app database.
    ///
    /// # Errors
    /// The database cannot be opened, keyed, or migrated.
    pub fn open(path: &Path, key: &Key, peer: Peer, fault: Fault) -> Result<Self> {
        let url = path.to_str().context("database path is not UTF-8")?;
        let mut conn = SqliteConnection::establish(url)?;
        crate::db::apply_key(&mut conn, key).map_err(|e| anyhow!("{e}"))?;
        diesel::sql_query(
            "CREATE TABLE IF NOT EXISTS messages (
                chat TEXT NOT NULL,
                sender TEXT NOT NULL,
                id TEXT NOT NULL,
                ts INTEGER NOT NULL,
                body TEXT,
                PRIMARY KEY (chat, sender, id)
            )",
        )
        .execute(&mut conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            peer,
            fault,
        })
    }

    /// Number of stored messages. Used by the redelivery check.
    ///
    /// # Errors
    /// The query fails.
    pub fn count(&self) -> Result<i64> {
        #[derive(diesel::QueryableByName)]
        struct N {
            #[diesel(sql_type = BigInt)]
            n: i64,
        }
        let mut conn = self
            .conn
            .lock()
            .map_err(|_| anyhow!("inbox lock poisoned"))?;
        let rows: Vec<N> =
            diesel::sql_query("SELECT count(*) AS n FROM messages").load(&mut *conn)?;
        Ok(rows.first().map_or(0, |r| r.n))
    }
}

#[async_trait::async_trait]
impl InboundDurabilityHook for Inbox {
    async fn on_messages(&self, _client: Arc<Client>, batch: &[InboundMessage]) -> Result<()> {
        // Only the allowlisted chat is stored; other chats are acknowledged
        // without being read or kept.
        let rows: Vec<_> = batch
            .iter()
            .filter(|m| self.peer.matches(&m.info.source))
            .map(|m| {
                (
                    m.info.source.chat.to_string(),
                    m.info.source.sender.to_string(),
                    m.info.id.to_string(),
                    m.info.timestamp.timestamp(),
                    m.message.text_content().map(str::to_owned),
                )
            })
            .collect();
        if rows.is_empty() {
            return Ok(());
        }
        match self.fault {
            Fault::None => {}
            Fault::RefuseCommits => return Err(anyhow!("commit refused by fault injection")),
            Fault::DelayCommits(d) => {
                log::warn!("holding {} message(s) uncommitted for {d:?}", rows.len());
                tokio::time::sleep(d).await;
            }
        }
        let conn = Arc::clone(&self.conn);
        tokio::task::spawn_blocking(move || -> Result<()> {
            let mut conn = conn.lock().map_err(|_| anyhow!("inbox lock poisoned"))?;
            conn.transaction(|c| {
                for (chat, sender, id, ts, body) in rows {
                    // Redelivery is expected; the primary key makes it idempotent.
                    diesel::sql_query(
                        "INSERT OR IGNORE INTO messages (chat, sender, id, ts, body)
                         VALUES (?, ?, ?, ?, ?)",
                    )
                    .bind::<Text, _>(chat)
                    .bind::<Text, _>(sender)
                    .bind::<Text, _>(id)
                    .bind::<BigInt, _>(ts)
                    .bind::<diesel::sql_types::Nullable<Text>, _>(body)
                    .execute(c)?;
                }
                Ok::<_, diesel::result::Error>(())
            })?;
            Ok(())
        })
        .await?
    }
}
