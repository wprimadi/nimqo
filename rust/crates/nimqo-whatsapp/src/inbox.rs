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

use crate::effects::Effect;
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
    /// Received messages not yet read here or on another device.
    #[diesel(sql_type = BigInt)]
    pub unread: i64,
    /// Name from the phone's address book, for 1:1 chats.
    #[diesel(sql_type = Nullable<Text>)]
    pub contact_name: Option<String>,
    /// Disappearing-message timer in seconds; 0 when off.
    #[diesel(sql_type = BigInt)]
    pub timer: i64,
    /// Muted on one of the account's devices, and not ended yet.
    #[diesel(sql_type = Bool)]
    pub muted: bool,
}

#[derive(Debug, diesel::QueryableByName)]
pub struct MessageRow {
    /// Storage order within a timestamp; the paging cursor with `ts`.
    #[diesel(sql_type = BigInt)]
    pub seq: i64,
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
    #[diesel(sql_type = Nullable<Text>)]
    pub contact_name: Option<String>,
    #[diesel(sql_type = Bool)]
    pub edited: bool,
    /// Every reaction's emoji, concatenated.
    #[diesel(sql_type = Nullable<Text>)]
    pub reactions: Option<String>,
    /// This account's own reaction, if any.
    #[diesel(sql_type = Nullable<Text>)]
    pub my_reaction: Option<String>,
    /// A picture can be shown for this message.
    #[diesel(sql_type = Bool)]
    pub has_media: bool,
    /// Replies: the quoted message's id, kind, and content as quoted.
    #[diesel(sql_type = Nullable<Text>)]
    pub reply_to: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub quote_kind: Option<String>,
    #[diesel(sql_type = Nullable<Text>)]
    pub quote_body: Option<String>,
    /// Whether the quoted message is own; None when it is not stored here.
    #[diesel(sql_type = Nullable<Bool>)]
    pub quote_from_me: Option<bool>,
    #[diesel(sql_type = Nullable<Text>)]
    pub quote_name: Option<String>,
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
                 coalesce(
                   (SELECT n.sender_name FROM messages n
                    WHERE n.chat = m.chat AND n.from_me = 0 AND n.sender_name <> ''
                    ORDER BY n.ts DESC LIMIT 1),
                   -- History names a person by number or by LID.
                   (SELECT name FROM push_names WHERE jid = m.chat),
                   (SELECT p.name FROM push_names p JOIN lid_map l ON l.lid = p.jid
                    WHERE l.pn = m.chat LIMIT 1)) END AS name,
               (SELECT COUNT(*) FROM messages u
                WHERE u.chat = m.chat AND u.from_me = 0 AND u.read = 0) AS unread,
               coalesce((SELECT name FROM contacts WHERE jid = m.chat),
                        (SELECT name FROM chat_names WHERE chat = m.chat
                         AND m.chat NOT LIKE '%@g.us')) AS contact_name,
               COALESCE((SELECT seconds FROM chat_timers WHERE chat = m.chat), 0) AS timer,
               EXISTS (SELECT 1 FROM chat_mutes WHERE chat = m.chat AND (until < 0
                       OR until > CAST(strftime('%s', 'now') AS INTEGER) * 1000)) AS muted
             FROM messages m
             WHERE m.rowid = (SELECT x.rowid FROM messages x WHERE x.chat = m.chat
                              ORDER BY x.ts DESC, x.rowid DESC LIMIT 1)
             ORDER BY m.ts DESC LIMIT ?",
        )
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }

    /// The oldest stored message of `chat` as (id, from me, timestamp), the
    /// anchor for asking the phone for history before it.
    ///
    /// # Errors
    /// The query fails.
    pub fn oldest(&self, chat: &str) -> Result<Option<(String, bool, i64)>> {
        #[derive(diesel::QueryableByName)]
        struct Oldest {
            #[diesel(sql_type = Text)]
            id: String,
            #[diesel(sql_type = diesel::sql_types::Bool)]
            from_me: bool,
            #[diesel(sql_type = BigInt)]
            ts: i64,
        }
        let mut conn = self.lock()?;
        let row: Option<Oldest> = diesel::OptionalExtension::optional(
            diesel::sql_query(
                "SELECT id, from_me, ts FROM messages WHERE chat = ? AND status <> 'pending'
             ORDER BY ts, rowid LIMIT 1",
            )
            .bind::<Text, _>(chat)
            .get_result(&mut *conn),
        )?;
        Ok(row.map(|r| (r.id, r.from_me, r.ts)))
    }

    /// The latest `limit` messages of `chat`, oldest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn messages(&self, chat: &str, limit: i64) -> Result<Vec<MessageRow>> {
        self.messages_before(chat, None, limit)
    }

    /// Up to `limit` messages older than `before` (a message's `(ts, seq)`),
    /// or the latest ones when `None`; oldest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn messages_before(
        &self,
        chat: &str,
        before: Option<(i64, i64)>,
        limit: i64,
    ) -> Result<Vec<MessageRow>> {
        let (ts, seq) = before.unwrap_or((i64::MAX, i64::MAX));
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT * FROM (
               SELECT m.id, m.sender, m.sender_name, m.ts, m.kind, m.body, m.from_me, m.status,
                 m.edited, m.rowid AS seq, m.media IS NOT NULL AND m.kind IN ('image', 'video', 'audio', 'document', 'sticker') AS has_media,
                 m.reply_to,
                 -- A quote's copy is the replier's claim: when the original is
                 -- stored, show it instead, so author and content always match.
                 CASE WHEN q.rowid IS NULL THEN m.quote_kind ELSE q.kind END AS quote_kind,
                 CASE WHEN q.rowid IS NULL THEN m.quote_body ELSE q.body END AS quote_body,
                 q.from_me AS quote_from_me,
                 coalesce((SELECT name FROM contacts WHERE jid = q.sender),
                          (SELECT name FROM chat_names WHERE chat = q.sender),
                          nullif(q.sender_name, '')) AS quote_name,
                 -- A person's chat name (from history) is their saved name.
                 coalesce((SELECT name FROM contacts WHERE jid = m.sender),
                          (SELECT name FROM chat_names WHERE chat = m.sender)) AS contact_name,
                 (SELECT group_concat(emoji, '') FROM reactions x
                  WHERE x.chat = m.chat AND x.target = m.id) AS reactions,
                 (SELECT emoji FROM reactions y WHERE y.chat = m.chat AND y.target = m.id
                  AND y.reactor = 'me') AS my_reaction
               FROM messages m
               -- Only an unambiguous match: in groups another member can
               -- reuse an id, and then the quote stays unattributed.
               LEFT JOIN messages q ON q.rowid = (
                 SELECT min(rowid) FROM messages
                 WHERE chat = m.chat AND id = m.reply_to HAVING count(*) = 1)
               WHERE m.chat = ? AND (m.ts < ? OR (m.ts = ? AND m.rowid < ?))
               ORDER BY m.ts DESC, m.rowid DESC LIMIT ?)
             ORDER BY ts, seq",
        )
        .bind::<Text, _>(chat)
        .bind::<BigInt, _>(ts)
        .bind::<BigInt, _>(ts)
        .bind::<BigInt, _>(seq)
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }

    /// Tells the app which chats changed outside a commit.
    pub fn notify_changed(&self, chats: Vec<String>) {
        self.notify(chats);
    }

    pub(crate) fn notify(&self, chats: Vec<String>) {
        if let (Some(notify), false) = (&self.on_commit, chats.is_empty()) {
            notify(chats);
        }
    }

    /// One history conversation: its messages and its name (a group's
    /// subject, or the saved name of a person).
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

    /// New messages first, then what changes them, in one transaction.
    pub(crate) fn commit(&self, rows: Vec<Row>, effects: &[Effect]) -> Result<()> {
        let mut conn = self.lock()?;
        conn.transaction(|c| {
            insert(c, rows)?;
            effects.iter().try_for_each(|e| e.apply(c))
        })?;
        Ok(())
    }

    #[cfg(test)]
    fn store(&self, rows: Vec<Row>) -> Result<()> {
        self.commit(rows, &[])
    }

    #[cfg(test)]
    pub(crate) fn apply_for_test(&self, effects: &[Effect]) {
        self.commit(Vec::new(), effects).unwrap();
    }

    #[cfg(test)]
    pub(crate) fn insert_timed_for_test(&self, chat: &str, id: &str, expires_at: Option<i64>) {
        self.insert_for_test(chat, chat, id);
        let mut conn = self.lock().unwrap();
        diesel::sql_query(
            "UPDATE messages SET expires_at = ? WHERE chat = ? AND sender = ? AND id = ?",
        )
        .bind::<Nullable<BigInt>, _>(expires_at)
        .bind::<Text, _>(chat)
        .bind::<Text, _>(chat)
        .bind::<Text, _>(id)
        .execute(&mut *conn)
        .unwrap();
    }

    #[cfg(test)]
    pub(crate) fn insert_media_for_test(&self, chat: &str, id: &str, media: Vec<u8>) {
        self.insert_kind_for_test(chat, id, "image", media);
    }

    #[cfg(test)]
    pub(crate) fn insert_kind_for_test(&self, chat: &str, id: &str, kind: &str, media: Vec<u8>) {
        let row = Row {
            chat: chat.into(),
            sender: chat.into(),
            id: id.into(),
            ts: 1,
            body: None,
            from_me: false,
            kind: kind.into(),
            sender_name: String::new(),
            status: "",
            read: true,
            expires_at: None,
            media: Some(media),
            quote: None,
        };
        self.commit(vec![row], &[]).unwrap();
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
            status: "",
            read: false,
            expires_at: None,
            media: None,
            quote: None,
        };
        self.commit(vec![row], &[]).unwrap();
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
        let mut rows = Vec::new();
        let mut effects = Vec::new();
        for m in batch {
            if m.info.source.chat.server == Server::Broadcast {
                continue; // status updates, not chats
            }
            // Diagnostics: protocol message types only, never content or ids.
            if let Some(p) = m.message.get_base_message().protocol_message.as_option() {
                log::info!(
                    "protocol message {:?} (from me: {})",
                    p.r#type,
                    m.info.source.is_from_me
                );
            }
            if let Some(e) = Effect::from_inbound(m) {
                effects.push(e);
            } else if let Some(r) = Row::from_inbound(m) {
                // A timed message tells us the chat's current timer.
                if let Some(s) = m.message.get_ephemeral_expiration() {
                    effects.push(Effect::Timer {
                        chat: r.chat.clone(),
                        seconds: s,
                    });
                }
                rows.push(r);
            }
        }
        if rows.is_empty() && effects.is_empty() {
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
        // Effects can name a 1:1 chat by LID (e.g. a timer turned off on the
        // phone) while its messages are stored by phone number.
        for e in &mut effects {
            if let Effect::Timer { seconds, .. } = e {
                log::info!("chat timer {}", if *seconds == 0 { "off" } else { "on" });
            }
            let chat = e.chat_mut();
            if let Ok(jid) = chat.parse::<whatsapp_rust::Jid>()
                && jid.is_lid()
            {
                *chat = crate::lids::phone_chat(self, &client, &jid).await;
            }
        }
        let mut chats: Vec<String> = rows.iter().map(|r| r.chat.clone()).collect();
        chats.extend(effects.iter().map(|e| e.chat().to_owned()));
        tokio::task::spawn_blocking(move || inbox.commit(rows, &effects)).await??;
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
               (chat, sender, id, ts, body, from_me, kind, sender_name, status, read,
                expires_at, media, reply_to, quote_kind, quote_body)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind::<Text, _>(r.chat)
        .bind::<Text, _>(r.sender)
        .bind::<Text, _>(r.id)
        .bind::<BigInt, _>(r.ts)
        .bind::<Nullable<Text>, _>(r.body)
        .bind::<Bool, _>(r.from_me)
        .bind::<Text, _>(r.kind)
        .bind::<Text, _>(r.sender_name)
        .bind::<Text, _>(r.status)
        .bind::<Bool, _>(r.read)
        .bind::<Nullable<BigInt>, _>(r.expires_at)
        .bind::<Nullable<diesel::sql_types::Binary>, _>(r.media)
        .bind::<Nullable<Text>, _>(r.quote.as_ref().map(|q| q.id.clone()))
        .bind::<Nullable<Text>, _>(r.quote.as_ref().map(|q| q.kind.clone()))
        .bind::<Nullable<Text>, _>(r.quote.and_then(|q| q.body))
        .execute(c)?;
    }
    Ok(())
}

/// Plain migrations after version 3, each applied with its version bump.
const LATER: &[(i64, &[&str])] = &[
    // Outbox: own messages carry a delivery state and send attempts.
    (
        4,
        &[
            "ALTER TABLE messages ADD COLUMN status TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE messages ADD COLUMN attempts INTEGER NOT NULL DEFAULT 0",
            "CREATE INDEX messages_outbox ON messages (status) WHERE status = 'pending'",
        ],
    ),
    // Own messages sent from the phone had no state to show; LID -> phone
    // number pairs learned from history.
    (
        5,
        &[
            "UPDATE messages SET status = 'sent' WHERE from_me = 1 AND status = ''",
            "CREATE TABLE lid_map (lid TEXT PRIMARY KEY, pn TEXT NOT NULL)",
        ],
    ),
    // Unread tracking; everything stored before it counts as read.
    (
        6,
        &[
            "ALTER TABLE messages ADD COLUMN read INTEGER NOT NULL DEFAULT 1",
            "CREATE INDEX messages_unread ON messages (chat) WHERE read = 0",
        ],
    ),
    // Names from the phone's address book, by phone-number jid.
    (
        7,
        &["CREATE TABLE contacts (jid TEXT PRIMARY KEY, name TEXT NOT NULL)"],
    ),
    // Edits and reactions.
    (
        8,
        &[
            "ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0",
            "CREATE TABLE reactions (chat TEXT NOT NULL, target TEXT NOT NULL,
               reactor TEXT NOT NULL, emoji TEXT NOT NULL,
               PRIMARY KEY (chat, target, reactor))",
        ],
    ),
    // Disappearing messages and per-chat timers.
    (
        9,
        &[
            "ALTER TABLE messages ADD COLUMN expires_at INTEGER",
            "CREATE INDEX messages_expiry ON messages (expires_at) WHERE expires_at IS NOT NULL",
            "CREATE TABLE chat_timers (chat TEXT PRIMARY KEY, seconds INTEGER NOT NULL)",
        ],
    ),
    // Profile pictures: which one is stored and when it was last checked.
    (
        10,
        &["CREATE TABLE avatars (jid TEXT PRIMARY KEY, picture_id TEXT, checked_at INTEGER)"],
    ),
    // What is needed to download a message's media later.
    (11, &["ALTER TABLE messages ADD COLUMN media BLOB"]),
    // Replies: the quoted message's id and a copy of its content.
    (
        12,
        &[
            "ALTER TABLE messages ADD COLUMN reply_to TEXT",
            "ALTER TABLE messages ADD COLUMN quote_kind TEXT",
            "ALTER TABLE messages ADD COLUMN quote_body TEXT",
            "CREATE INDEX messages_chat_id ON messages (chat, id)",
        ],
    ),
    // Profile names from history, for people not in the address book.
    (
        13,
        &["CREATE TABLE push_names (jid TEXT PRIMARY KEY, name TEXT NOT NULL)"],
    ),
    // Names saved by LID used to be dropped: empty the address book so the
    // next connection loads it again, complete (load_contacts_once).
    (14, &["DELETE FROM contacts"]),
    // Muted chats; tasks done once per store (loading the mutes is one).
    (
        15,
        &[
            "CREATE TABLE chat_mutes (chat TEXT PRIMARY KEY, until INTEGER NOT NULL)",
            "CREATE TABLE done_once (task TEXT PRIMARY KEY)",
        ],
    ),
];

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
        for (target, steps) in LATER {
            if version < *target {
                for sql in *steps {
                    diesel::sql_query(*sql).execute(c)?;
                }
                diesel::sql_query(format!("PRAGMA user_version = {target}")).execute(c)?;
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
    /// Delivery state of own messages; never "pending", which belongs to
    /// the outbox and would make it send the message again.
    pub status: &'static str,
    pub read: bool,
    /// Disappearing messages: when to delete it (unix seconds).
    pub expires_at: Option<i64>,
    /// The encoded media message (keys, URL, thumbnail), for downloading.
    pub media: Option<Vec<u8>>,
    /// The message this one replies to.
    pub quote: Option<crate::replies::Quote>,
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
            // Sent from the phone: the server has it, receipts move it on.
            status: if src.is_from_me { "sent" } else { "" },
            read: src.is_from_me,
            expires_at: m
                .message
                .get_ephemeral_expiration()
                .map(|s| m.info.timestamp.timestamp() + i64::from(s)),
            media: media_of(&m.message),
            quote: crate::replies::quote_of(&m.message),
        })
    }
}

/// Own messages are "me"; others use the phone number when the message
/// carries it, so live and history copies of a message share one key.
pub(crate) fn sender_key(src: &MessageSource) -> String {
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
pub(crate) fn chat_key(src: &MessageSource) -> String {
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

/// The encoded media message, kept so the file can be downloaded later.
#[must_use]
pub fn media_of(message: &wa::Message) -> Option<Vec<u8>> {
    use whatsapp_rust::buffa::Message as _;
    let base = message.get_base_message();
    if let Some(image) = base.image_message.as_option() {
        return Some(image.encode_to_vec());
    }
    if let Some(video) = base.video_message.as_option() {
        return Some(video.encode_to_vec());
    }
    if let Some(audio) = base.audio_message.as_option() {
        return Some(audio.encode_to_vec());
    }
    if let Some(sticker) = base.sticker_message.as_option() {
        return Some(sticker.encode_to_vec());
    }
    Some(base.document_message.as_option()?.encode_to_vec())
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

    #[test]
    fn pages_walk_back_without_gaps_or_repeats() {
        let path = std::env::temp_dir().join(format!("nimqo-pages-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([4; 32]), Fault::None).unwrap();
        let c = "62811@s.whatsapp.net";
        // Five messages, three sharing a timestamp.
        let rows = [(1, "a"), (2, "b"), (2, "c"), (2, "d"), (3, "e")]
            .map(|(ts, id)| row(c, id, ts, false, ""));
        inbox.store(rows.into()).unwrap();
        let mut seen = Vec::new();
        let mut before = None;
        loop {
            let page = inbox.messages_before(c, before, 2).unwrap();
            if page.is_empty() {
                break;
            }
            before = Some((page[0].ts, page[0].seq));
            seen.splice(0..0, page.into_iter().map(|m| m.id));
        }
        assert_eq!(seen, ["a", "b", "c", "d", "e"]);
        assert_eq!(inbox.oldest(c).unwrap().map(|o| o.0), Some("a".into()));
        assert_eq!(inbox.oldest("none@g.us").unwrap(), None);
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }

    #[test]
    fn later_migrations_run_in_version_order() {
        assert!(LATER.windows(2).all(|w| w[0].0 < w[1].0));
    }

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
            status: "",
            read: from_me,
            expires_at: None,
            media: None,
            quote: None,
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
        inbox.commit(vec![sent(ana, "m1")], &[]).unwrap();
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
