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
    #[diesel(sql_type = Text)]
    pub body: String,
}

impl Inbox {
    /// Stores an own text message as pending.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn enqueue(&self, chat: &str, id: &str, ts: i64, body: &str) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "INSERT INTO messages (chat, sender, id, ts, body, from_me, kind, status)
             VALUES (?, ?, ?, ?, ?, 1, 'text', 'pending')",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .bind::<BigInt, _>(ts)
        .bind::<Text, _>(body)
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
            "SELECT chat, id, body FROM messages
             WHERE status = 'pending' AND sender = ? ORDER BY ts, rowid",
        )
        .bind::<Text, _>(ME)
        .load(&mut *conn)?)
    }

    /// Records a failed send; after [`MAX_ATTEMPTS`] the message is failed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn attempt_failed(&self, id: &str) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::sql_query(
            "UPDATE messages SET attempts = attempts + 1,
               status = CASE WHEN attempts + 1 >= ? THEN 'failed' ELSE status END
             WHERE sender = ? AND id = ? AND status = 'pending'",
        )
        .bind::<BigInt, _>(MAX_ATTEMPTS)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .execute(&mut *conn)?;
        Ok(())
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
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
