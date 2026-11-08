//! Outbox (plan 10.5): an own message is stored as `pending` before it is
//! sent, with an id chosen up front. A retry reuses the id, so a send that
//! reached the server before a crash is not delivered twice.

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Text};

use crate::inbox::{Inbox, ME};

/// Delivery state of an own message. Only ever moves forward.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Status {
    Pending,
    Sent,
    Delivered,
    Read,
    /// Gave up after [`MAX_ATTEMPTS`]; only reachable from `Pending`.
    Failed,
}

impl Status {
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::Sent => "sent",
            Self::Delivered => "delivered",
            Self::Read => "read",
            Self::Failed => "failed",
        }
    }
}

pub const MAX_ATTEMPTS: i64 = 5;

/// An own message waiting to be sent.
#[derive(Debug, diesel::QueryableByName)]
pub struct Pending {
    #[diesel(sql_type = Text)]
    pub chat: String,
    #[diesel(sql_type = Text)]
    pub id: String,
    /// Text, a caption, or a document's file name.
    #[diesel(sql_type = diesel::sql_types::Nullable<Text>)]
    pub body: Option<String>,
    /// "text", "image", or "document".
    #[diesel(sql_type = Text)]
    pub kind: String,
    /// For files: the media message drafted before upload (type, name,
    /// thumbnail), completed when sent.
    #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Binary>)]
    pub media: Option<Vec<u8>>,
    /// The id of the message this one replies to.
    #[diesel(sql_type = diesel::sql_types::Nullable<Text>)]
    pub reply_to: Option<String>,
    /// The chat's timer when it was queued, sent with it.
    #[diesel(sql_type = diesel::sql_types::Nullable<BigInt>)]
    pub timer: Option<i64>,
}

impl Inbox {
    /// Stores an own text message as pending.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue(&self, chat: &str, id: &str, ts: i64, body: &str) -> Result<()> {
        self.enqueue_reply(chat, id, ts, body, None)
    }

    /// Stores an own text message as pending, replying to `quote` if given.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue_reply(
        &self,
        chat: &str,
        id: &str,
        ts: i64,
        body: &str,
        quote: Option<&crate::replies::Quoted>,
    ) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "INSERT INTO messages (chat, sender, id, ts, body, from_me, kind, status, expires_at,
               reply_to, quote_kind, quote_body)
             VALUES (?, ?, ?, ?, ?, 1, 'text', 'pending',
               ? + (SELECT NULLIF(seconds, 0) FROM chat_timers WHERE chat = ?), ?, ?, ?)",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .bind::<BigInt, _>(ts)
        .bind::<Text, _>(body)
        .bind::<BigInt, _>(ts)
        .bind::<Text, _>(chat)
        .bind::<diesel::sql_types::Nullable<Text>, _>(quote.map(|q| q.id.as_str()))
        .bind::<diesel::sql_types::Nullable<Text>, _>(quote.map(|q| q.kind.as_str()))
        .bind::<diesel::sql_types::Nullable<Text>, _>(quote.and_then(|q| q.body.as_deref()))
        .execute(&mut *conn)?;
        Ok(())
    }

    /// Stores an own file message as pending: `kind` is "image" or
    /// "document", `draft` the encoded media message before upload. The
    /// file itself is stored by `Attachments::store_outgoing`.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue_file(
        &self,
        chat: &str,
        id: &str,
        ts: i64,
        kind: &str,
        body: Option<&str>,
        draft: &[u8],
    ) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "INSERT INTO messages (chat, sender, id, ts, body, from_me, kind, status, media,
               expires_at)
             VALUES (?, ?, ?, ?, ?, 1, ?, 'pending', ?,
               ? + (SELECT NULLIF(seconds, 0) FROM chat_timers WHERE chat = ?))",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .bind::<BigInt, _>(ts)
        .bind::<diesel::sql_types::Nullable<Text>, _>(body)
        .bind::<Text, _>(kind)
        .bind::<diesel::sql_types::Binary, _>(draft)
        .bind::<BigInt, _>(ts)
        .bind::<Text, _>(chat)
        .execute(&mut *conn)?;
        Ok(())
    }

    /// An own status update this device posted: the phone does not echo
    /// it back, so it is stored here, gone after a day like the rest.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn store_own_status(
        &self,
        id: &str,
        ts: i64,
        kind: &str,
        body: Option<String>,
        media: Option<Vec<u8>>,
    ) -> Result<()> {
        use crate::inbox::{Row, STATUS, STATUS_LIFETIME};
        let row = Row {
            chat: STATUS.to_owned(),
            sender: ME.to_owned(),
            id: id.to_owned(),
            ts,
            body,
            from_me: true,
            kind: kind.to_owned(),
            sender_name: String::new(),
            status: "sent",
            read: true,
            expires_at: Some(ts + STATUS_LIFETIME),
            media,
            quote: None,
        };
        self.commit(vec![row], &[])
    }

    /// Replaces an own message's draft with the media message as sent.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_sent_media(&self, id: &str, media: &[u8]) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query("UPDATE messages SET media = ? WHERE sender = ? AND id = ?")
            .bind::<diesel::sql_types::Binary, _>(media)
            .bind::<Text, _>(ME)
            .bind::<Text, _>(id)
            .execute(&mut *conn)?;
        Ok(())
    }

    /// Pending messages, oldest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn pending(&self) -> Result<Vec<Pending>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT chat, id, body, kind, media, reply_to, expires_at - ts AS timer FROM messages
             WHERE status = 'pending' AND sender = ? ORDER BY ts, rowid",
        )
        .bind::<Text, _>(ME)
        .load(&mut *conn)?)
    }

    /// Queues an own failed message (`seq` in `chat`) again, its attempts
    /// reset. False when it is not a failed own message.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn retry_failed(&self, chat: &str, seq: i64) -> Result<bool> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "UPDATE messages SET status = 'pending', attempts = 0
             WHERE rowid = ? AND chat = ? AND sender = ? AND status = 'failed'",
        )
        .bind::<BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .execute(&mut *conn)?
            == 1)
    }

    /// Whether `chat` has anything stored: messages go only to chats that
    /// are already here, never to a number typed in.
    ///
    /// # Errors
    /// The query fails.
    pub fn knows_chat(&self, chat: &str) -> Result<bool> {
        #[derive(diesel::QueryableByName)]
        struct N {
            #[diesel(sql_type = diesel::sql_types::Bool)]
            known: bool,
        }
        let mut conn = self.lock()?;
        let n: N =
            diesel::sql_query("SELECT EXISTS (SELECT 1 FROM messages WHERE chat = ?) AS known")
                .bind::<Text, _>(chat)
                .get_result(&mut *conn)?;
        Ok(n.known)
    }

    /// Records a failed send; after [`MAX_ATTEMPTS`] the message is failed.
    /// Returns its chat.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn attempt_failed(&self, id: &str) -> Result<Option<String>> {
        #[derive(diesel::QueryableByName)]
        struct Chat {
            #[diesel(sql_type = Text)]
            chat: String,
        }
        let mut conn = self.lock()?;
        let rows: Vec<Chat> = diesel::sql_query(
            "UPDATE messages SET attempts = attempts + 1,
               status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE status END
             WHERE sender = ? AND id = ? AND status = 'pending' RETURNING chat",
        )
        .bind::<BigInt, _>(MAX_ATTEMPTS)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .load(&mut *conn)?;
        Ok(rows.into_iter().next().map(|r| r.chat))
    }

    /// Advances an own message's state; never moves it backwards, so a late
    /// "delivered" cannot undo "read". Returns the chat when a row changed.
    ///
    /// Matched by id among own messages only: ids are generated here, and a
    /// receipt may name the chat by LID or by phone number.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn advance(&self, id: &str, to: Status) -> Result<Option<String>> {
        #[derive(diesel::QueryableByName)]
        struct Chat {
            #[diesel(sql_type = Text)]
            chat: String,
        }
        let allowed: &[&str] = match to {
            Status::Pending => &[],
            Status::Sent | Status::Failed => &["pending"],
            Status::Delivered => &["pending", "sent"],
            Status::Read => &["pending", "sent", "delivered"],
        };
        let mut conn = self.lock()?;
        for from in allowed {
            let changed: Vec<Chat> = diesel::sql_query(
                "UPDATE messages SET status = ? WHERE sender = ? AND id = ? AND status = ?
                 RETURNING chat",
            )
            .bind::<Text, _>(to.as_str())
            .bind::<Text, _>(ME)
            .bind::<Text, _>(id)
            .bind::<Text, _>(*from)
            .load(&mut *conn)?;
            if let Some(c) = changed.into_iter().next() {
                return Ok(Some(c.chat));
            }
        }
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::Fault;
    use crate::vault::Key;

    #[test]
    fn an_own_status_is_kept_as_sent_and_never_resent() {
        let path = std::env::temp_dir().join(format!("nimqo-own-status-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([4; 32]), Fault::None).unwrap();
        inbox
            .store_own_status("S", 100, "text", Some("hello".into()), None)
            .unwrap();
        let m = inbox.messages(crate::inbox::STATUS, 10).unwrap();
        assert_eq!((m[0].sender.as_str(), m[0].id.as_str()), (ME, "S"));
        assert!(inbox.pending().unwrap().is_empty(), "not queued again");
        let _ = std::fs::remove_file(&path);
    }

    #[test]
    fn states_only_move_forward_and_failures_are_bounded() {
        let path = std::env::temp_dir().join(format!("nimqo-outbox-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([3; 32]), Fault::None).unwrap();
        let peer = "62811@s.whatsapp.net";
        inbox.enqueue(peer, "A", 1, "hi").unwrap();
        inbox.enqueue(peer, "B", 2, "again").unwrap();
        let ids: Vec<_> = inbox.pending().unwrap().into_iter().map(|p| p.id).collect();
        assert_eq!(ids, ["A", "B"]);

        let status = |id: &str| {
            let m = inbox.messages(peer, 10).unwrap();
            m.into_iter().find(|m| m.id == id).unwrap().status
        };
        assert_eq!(
            inbox.advance("A", Status::Read).unwrap().as_deref(),
            Some(peer)
        );
        assert_eq!(
            inbox.advance("A", Status::Delivered).unwrap(),
            None,
            "no going back"
        );
        assert_eq!(status("A"), "read");

        for _ in 0..MAX_ATTEMPTS {
            inbox.attempt_failed("B").unwrap();
        }
        assert_eq!(status("B"), "failed");
        assert!(inbox.pending().unwrap().is_empty());
        let seq = |id: &str| {
            let m = inbox.messages(peer, 10).unwrap();
            m.into_iter().find(|m| m.id == id).unwrap().seq
        };
        assert!(
            !inbox.retry_failed(peer, seq("A")).unwrap(),
            "only failed ones"
        );
        assert!(
            !inbox.retry_failed("x@s.whatsapp.net", seq("B")).unwrap(),
            "seq is per chat"
        );
        assert!(inbox.retry_failed(peer, seq("B")).unwrap());
        assert_eq!(status("B"), "pending");
        inbox.attempt_failed("B").unwrap();
        assert_eq!(status("B"), "pending", "attempts start again");
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
