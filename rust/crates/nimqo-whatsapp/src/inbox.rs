//! Encrypted message store behind upstream's `InboundDurabilityHook`.
//!
//! Every chat is stored (read-only display); sending stays allowlisted
//! elsewhere.
//!
//! Upstream acknowledges a message as soon as it is decrypted unless a
//! durability hook is registered. With this hook, a message is acknowledged
//! only after it is committed here; a failed or interrupted commit leaves it
//! on the server for redelivery (plan 10.4).

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result, anyhow};
use diesel::sql_types::{BigInt, Bool, Nullable, Text};
use diesel::{Connection, RunQueryDsl, SqliteConnection};
use whatsapp_rust::prelude::{MessageExt, wa};
use whatsapp_rust::types::durability_hook::InboundMessage;
use whatsapp_rust::wacore::types::message::MessageSource;
use whatsapp_rust::{Client, InboundDurabilityHook, Server};

use crate::vault::Key;

/// Called after a commit with the chats that gained messages.
pub type OnCommit = Arc<dyn Fn(Vec<String>) + Send + Sync>;

/// Fault injection for redelivery tests. Always `None` outside tests.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    None,
    /// Refuse every commit.
    RefuseCommits,
    /// Wait before committing, leaving time to `kill -9` the process.
    DelayCommits(Duration),
}

#[derive(Clone)]
pub struct Inbox {
    conn: Arc<Mutex<SqliteConnection>>,
    fault: Fault,
    on_commit: Option<OnCommit>,
}

/// Latest message of one chat, for the chat list.
#[derive(Debug, diesel::QueryableByName)]
pub struct ChatRow {
    #[diesel(sql_type = Text)]
    pub chat: String,
    /// Group subject, or the other person's push name.
    #[diesel(sql_type = Nullable<Text>)]
    pub name: Option<String>,
    #[diesel(sql_type = BigInt)]
    pub ts: i64,
    #[diesel(sql_type = Text)]
    pub kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub body: Option<String>,
    #[diesel(sql_type = Bool)]
    pub from_me: bool,
}

#[derive(Debug, diesel::QueryableByName)]
pub struct MessageRow {
    #[diesel(sql_type = Text)]
    pub id: String,
    #[diesel(sql_type = Text)]
    pub sender: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub sender_name: Option<String>,
    #[diesel(sql_type = BigInt)]
    pub ts: i64,
    #[diesel(sql_type = Text)]
    pub kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub body: Option<String>,
    #[diesel(sql_type = Bool)]
    pub from_me: bool,
    /// Delivery state of own messages; empty for received ones.
    #[diesel(sql_type = Text)]
    pub status: String,
}

impl Inbox {
    /// Opens (or creates) the encrypted app database.
    ///
    /// # Errors
    /// The database cannot be opened, keyed, or migrated.
    pub fn open(path: &Path, key: &Key, fault: Fault) -> Result<Self> {
        let url = path.to_str().context("database path is not UTF-8")?;
        let mut conn = SqliteConnection::establish(url)?;
        crate::db::apply_key(&mut conn, key).map_err(|e| anyhow!("{e}"))?;
        migrate(&mut conn)?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            fault,
            on_commit: None,
        })
    }

    /// Must be set before the inbox is handed to the client.
    pub fn set_on_commit(&mut self, f: OnCommit) {
        self.on_commit = Some(f);
    }

    /// Chats by most recent message.
    ///
    /// # Errors
    /// The query fails.
    pub fn chats(&self, limit: i64) -> Result<Vec<ChatRow>> {
        let mut conn = self.lock()?;
        // ponytail: correlated subqueries on the (chat, ts) index; add a
        // chats table if large accounts make this slow.
        Ok(diesel::sql_query(
            "SELECT m.chat, m.ts, m.kind, m.body, m.from_me,
               CASE WHEN m.chat LIKE '%@g.us'
                 THEN (SELECT name FROM chat_names WHERE chat = m.chat) ELSE
                 (SELECT n.sender_name FROM messages n
                  WHERE n.chat = m.chat AND n.from_me = 0 AND n.sender_name <> ''
                  ORDER BY n.ts DESC LIMIT 1) END AS name
             FROM messages m
             WHERE m.rowid = (SELECT x.rowid FROM messages x WHERE x.chat = m.chat
                              ORDER BY x.ts DESC, x.rowid DESC LIMIT 1)
             ORDER BY m.ts DESC LIMIT ?",
        )
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }

    /// The latest `limit` messages of `chat`, oldest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn messages(&self, chat: &str, limit: i64) -> Result<Vec<MessageRow>> {
        let mut conn = self.lock()?;
        // ponytail: newest page only; scrollback paging comes with the timeline.
        Ok(diesel::sql_query(
            "SELECT * FROM (
               SELECT id, sender, sender_name, ts, kind, body, from_me, status, rowid AS r
               FROM messages WHERE chat = ? ORDER BY ts DESC, rowid DESC LIMIT ?)
             ORDER BY ts, r",
        )
        .bind::<Text, _>(chat)
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }

    pub(crate) fn notify(&self, chats: Vec<String>) {
        if let (Some(notify), false) = (&self.on_commit, chats.is_empty()) {
            notify(chats);
        }
    }

    /// One history conversation: its messages and, for groups, the subject.
    pub(crate) fn import(&self, chat: &str, name: Option<String>, rows: Vec<Row>) -> Result<()> {
        let mut conn = self.lock()?;
        conn.transaction(|c| {
            if let Some(name) = name {
                diesel::sql_query("INSERT OR REPLACE INTO chat_names (chat, name) VALUES (?, ?)")
                    .bind::<Text, _>(chat)
                    .bind::<Text, _>(name)
                    .execute(c)?;
            }
            insert(c, rows)
        })?;
        Ok(())
    }

    fn store(&self, rows: Vec<Row>) -> Result<()> {
        let mut conn = self.lock()?;
        conn.transaction(|c| insert(c, rows))?;
        Ok(())
    }

    #[cfg(test)]
    pub(crate) fn insert_for_test(&self, chat: &str, sender: &str, id: &str) {
        let row = Row {
            chat: chat.into(),
            sender: sender.into(),
            id: id.into(),
            ts: 1,
            body: None,
            from_me: false,
            kind: "text".into(),
            sender_name: String::new(),
        };
        self.store(vec![row]).unwrap();
    }

    pub(crate) fn lock(&self) -> Result<std::sync::MutexGuard<'_, SqliteConnection>> {
        self.conn.lock().map_err(|_| anyhow!("inbox lock poisoned"))
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
        let mut conn = self.lock()?;
        let rows: Vec<N> =
            diesel::sql_query("SELECT count(*) AS n FROM messages").load(&mut *conn)?;
        Ok(rows.first().map_or(0, |r| r.n))
    }
}

#[async_trait::async_trait]
impl InboundDurabilityHook for Inbox {
    async fn on_messages(&self, client: Arc<Client>, batch: &[InboundMessage]) -> Result<()> {
        let rows: Vec<Row> = batch.iter().filter_map(Row::from_inbound).collect();
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
        let inbox = self.clone();
        let has_lid = rows
            .iter()
            .any(|r| r.chat.ends_with("@lid") || r.sender.ends_with("@lid"));
        let mut chats: Vec<String> = rows.iter().map(|r| r.chat.clone()).collect();
        tokio::task::spawn_blocking(move || inbox.store(rows)).await??;
        chats.sort_unstable();
        chats.dedup();
        self.notify(chats);
        if has_lid {
            crate::lids::resolve(self, &client).await;
        }
        Ok(())
    }
}

/// Redelivery and history overlap are expected; the primary key makes
/// inserts idempotent.
fn insert(c: &mut SqliteConnection, rows: Vec<Row>) -> diesel::QueryResult<()> {
    for r in rows {
        diesel::sql_query(
            "INSERT OR IGNORE INTO messages
               (chat, sender, id, ts, body, from_me, kind, sender_name)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind::<Text, _>(r.chat)
        .bind::<Text, _>(r.sender)
        .bind::<Text, _>(r.id)
        .bind::<BigInt, _>(r.ts)
        .bind::<Nullable<Text>, _>(r.body)
        .bind::<Bool, _>(r.from_me)
        .bind::<Text, _>(r.kind)
        .bind::<Text, _>(r.sender_name)
        .execute(c)?;
    }
    Ok(())
}

/// Schema by `PRAGMA user_version`. Version 0 is the Phase 0 table.
fn migrate(conn: &mut SqliteConnection) -> Result<()> {
    #[derive(diesel::QueryableByName)]
    struct V {
        #[diesel(sql_type = BigInt)]
        user_version: i64,
    }
    let version = diesel::sql_query("PRAGMA user_version")
        .load::<V>(conn)?
        .first()
        .map_or(0, |v| v.user_version);
    conn.transaction(|c| {
        if version < 1 {
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
            .execute(c)?;
            for sql in [
                "ALTER TABLE messages ADD COLUMN from_me INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE messages ADD COLUMN kind TEXT NOT NULL DEFAULT 'text'",
                "ALTER TABLE messages ADD COLUMN sender_name TEXT NOT NULL DEFAULT ''",
                "CREATE INDEX messages_chat_ts ON messages (chat, ts)",
                "PRAGMA user_version = 1",
            ] {
                diesel::sql_query(sql).execute(c)?;
            }
        }
        if version < 2 {
            for sql in [
                "CREATE TABLE messages2 (
                    chat TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    id TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    body TEXT,
                    from_me INTEGER NOT NULL DEFAULT 0,
                    kind TEXT NOT NULL DEFAULT 'text',
                    sender_name TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (chat, id)
                )",
                "INSERT OR IGNORE INTO messages2
                   SELECT chat, sender, id, ts, body, from_me, kind, sender_name FROM messages",
                "DROP TABLE messages",
                "ALTER TABLE messages2 RENAME TO messages",
                "CREATE INDEX messages_chat_ts ON messages (chat, ts)",
                "CREATE TABLE chat_names (chat TEXT PRIMARY KEY, name TEXT NOT NULL)",
                "PRAGMA user_version = 2",
            ] {
                diesel::sql_query(sql).execute(c)?;
            }
        }
        if version < 3 {
            // Back to (chat, sender, id): message ids are chosen by the
            // sending client, so keying on (chat, id) let one group member
            // suppress another's message by reusing its id. Senders are
            // normalized instead (see `sender_key`).
            for sql in [
                "CREATE TABLE messages3 (
                    chat TEXT NOT NULL,
                    sender TEXT NOT NULL,
                    id TEXT NOT NULL,
                    ts INTEGER NOT NULL,
                    body TEXT,
                    from_me INTEGER NOT NULL DEFAULT 0,
                    kind TEXT NOT NULL DEFAULT 'text',
                    sender_name TEXT NOT NULL DEFAULT '',
                    PRIMARY KEY (chat, sender, id)
                )",
                "INSERT OR IGNORE INTO messages3 SELECT * FROM messages",
                "DROP TABLE messages",
                "ALTER TABLE messages3 RENAME TO messages",
                "CREATE INDEX messages_chat_ts ON messages (chat, ts)",
                "PRAGMA user_version = 3",
            ] {
                diesel::sql_query(sql).execute(c)?;
            }
        }
        if version < 4 {
            // Outbox: own messages carry a delivery state and send attempts.
            for sql in [
                "ALTER TABLE messages ADD COLUMN status TEXT NOT NULL DEFAULT ''",
                "ALTER TABLE messages ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0",
                "CREATE INDEX messages_outbox ON messages (status) WHERE status = 'pending'",
                "PRAGMA user_version = 4",
            ] {
                diesel::sql_query(sql).execute(c)?;
            }
        }
        Ok::<_, diesel::result::Error>(())
    })?;
    Ok(())
}

pub(crate) struct Row {
    pub chat: String,
    pub sender: String,
    pub id: String,
    pub ts: i64,
    pub body: Option<String>,
    pub from_me: bool,
    pub kind: String,
    pub sender_name: String,
}

impl Row {
    fn from_inbound(m: &InboundMessage) -> Option<Self> {
        let src = &m.info.source;
        if src.chat.server == Server::Broadcast {
            return None; // status updates, not chats
        }
        let (kind, body) = classify(&m.message)?;
        Some(Self {
            chat: chat_key(src),
            sender: sender_key(src),
            id: m.info.id.to_string(),
            ts: m.info.timestamp.timestamp(),
            body,
            from_me: src.is_from_me,
            kind: kind.to_owned(),
            sender_name: m.info.push_name.to_string(),
        })
    }
}

/// Own messages are "me"; others use the phone number when the message
/// carries it, so live and history copies of a message share one key.
fn sender_key(src: &MessageSource) -> String {
    if src.is_from_me {
        return ME.to_owned();
    }
    src.sender_alt
        .as_ref()
        .filter(|j| j.is_pn())
        .unwrap_or(&src.sender)
        .to_non_ad_string()
}

/// Sender key of the user's own messages.
pub(crate) const ME: &str = "me";

/// One chat per person: a one-to-one chat addressed by LID is filed under
/// the phone number when the message carries it, so both addressings of the
/// same contact land in the same chat.
fn chat_key(src: &MessageSource) -> String {
    if src.is_group || src.chat.is_pn() {
        return src.chat.to_non_ad_string();
    }
    let alt = if src.is_from_me {
        src.recipient_alt.as_ref()
    } else {
        src.sender_alt.as_ref()
    };
    alt.filter(|j| j.is_pn())
        .unwrap_or(&src.chat)
        .to_non_ad_string()
}

/// What the timeline shows, or `None` for messages that only change other
/// messages or carry keys (handled in later steps, not displayed).
pub(crate) fn classify(message: &wa::Message) -> Option<(&'static str, Option<String>)> {
    if let Some(text) = message.text_content() {
        return Some(("text", Some(text.to_owned())));
    }
    let b = message.get_base_message();
    if let Some(m) = b.image_message.as_option() {
        return Some(("image", m.caption.clone()));
    }
    if let Some(m) = b.video_message.as_option() {
        return Some(("video", m.caption.clone()));
    }
    if b.audio_message.as_option().is_some() {
        return Some(("audio", None));
    }
    if let Some(m) = b.document_message.as_option() {
        return Some(("document", m.file_name.clone()));
    }
    if b.sticker_message.as_option().is_some() {
        return Some(("sticker", None));
    }
    let silent = b.protocol_message.as_option().is_some()
        || b.reaction_message.as_option().is_some()
        || b.sender_key_distribution_message.as_option().is_some();
    (!silent).then_some(("unsupported", None))
}

#[cfg(test)]
mod tests {
    use whatsapp_rust::Jid;
    use whatsapp_rust::prelude::*;

    use super::*;

    fn row(chat: &str, id: &str, ts: i64, from_me: bool, name: &str) -> Row {
        Row {
            chat: chat.into(),
            sender: chat.into(),
            id: id.into(),
            ts,
            body: Some(format!("body {id}")),
            from_me,
            kind: "text".into(),
            sender_name: name.into(),
        }
    }

    #[test]
    fn chats_list_latest_first_and_redelivery_is_idempotent() {
        let path = std::env::temp_dir().join(format!("nimqo-inbox-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([7; 32]), Fault::None).unwrap();
        let (alice, group) = ("111@s.whatsapp.net", "222@g.us");
        inbox
            .store(vec![
                row(alice, "a1", 10, false, "Alice"),
                row(alice, "a2", 30, true, ""),
                row(group, "g1", 20, false, "Bob"),
            ])
            .unwrap();
        inbox
            .store(vec![row(alice, "a1", 10, false, "Alice")])
            .unwrap();

        let chats = inbox.chats(10).unwrap();
        let order: Vec<_> = chats.iter().map(|c| (c.chat.as_str(), c.ts)).collect();
        assert_eq!(order, [(alice, 30), (group, 20)]);
        assert_eq!(
            chats[0].name.as_deref(),
            Some("Alice"),
            "own messages carry no name"
        );
        assert!(chats[0].from_me);
        assert_eq!(chats[1].name, None, "a member's name is not the group's");

        let ids: Vec<_> = inbox
            .messages(alice, 10)
            .unwrap()
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(ids, ["a1", "a2"]);
        assert_eq!(inbox.count().unwrap(), 3);
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn history_overlapping_live_messages_is_stored_once_and_names_groups() {
        let path = std::env::temp_dir().join(format!("nimqo-history-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([9; 32]), Fault::None).unwrap();
        let group = "1-2@g.us";
        let ana = "62811@s.whatsapp.net";
        let sent = |sender: &str, id: &str| Row {
            sender: sender.into(),
            ..row(group, id, 10, false, "Ana")
        };
        inbox.store(vec![sent(ana, "m1")]).unwrap();
        // The same message again, plus another member reusing its id.
        let again = vec![sent(ana, "m1"), sent("62999@s.whatsapp.net", "m1")];
        inbox.import(group, Some("Family".into()), again).unwrap();
        assert_eq!(
            inbox.count().unwrap(),
            2,
            "a reused id must not hide a message"
        );
        assert_eq!(inbox.chats(10).unwrap()[0].name.as_deref(), Some("Family"));
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn lid_chats_are_filed_under_the_phone_number() {
        let lid = Jid::lid("999");
        let pn = Jid::pn("628111");
        let incoming = MessageSource {
            chat: lid.clone(),
            sender: lid.clone(),
            sender_alt: Some(pn.clone()),
            ..MessageSource::default()
        };
        assert_eq!(chat_key(&incoming), "628111@s.whatsapp.net");
        let sent_from_phone = MessageSource {
            chat: lid.clone(),
            is_from_me: true,
            sender_alt: Some(Jid::pn("62own")),
            recipient_alt: Some(pn),
            ..MessageSource::default()
        };
        assert_eq!(chat_key(&sent_from_phone), "628111@s.whatsapp.net");
        let unknown = MessageSource {
            chat: lid,
            ..MessageSource::default()
        };
        assert_eq!(chat_key(&unknown), "999@lid");
    }

    #[test]
    fn key_only_and_reaction_messages_are_not_displayed() {
        let mut m = wa::Message::default();
        m.reaction_message =
            whatsapp_rust::buffa::MessageField::some(wa::message::ReactionMessage::default());
        assert_eq!(classify(&m), None);
        assert_eq!(
            classify(&wa::Message::default()),
            Some(("unsupported", None))
        );
        let text = wa::Message::text("hi");
        assert_eq!(classify(&text), Some(("text", Some("hi".into()))));
    }
}
