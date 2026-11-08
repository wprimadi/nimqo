//! Pinned and archived chats and starred messages, as set on any of the
//! account's devices.

use anyhow::Result;
use diesel::sql_types::{BigInt, Bool, Text};
use diesel::{OptionalExtension, RunQueryDsl};

use crate::inbox::Inbox;
use crate::search::Hit;

impl Inbox {
    /// Pins `chat` as of `at` (milliseconds since 1970); None unpins it.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_pinned(&self, chat: &str, at: Option<i64>) -> Result<()> {
        let mut conn = self.lock()?;
        match at {
            Some(at) => {
                diesel::sql_query("INSERT OR REPLACE INTO chat_pins (chat, ts) VALUES (?, ?)")
                    .bind::<Text, _>(chat)
                    .bind::<BigInt, _>(at)
                    .execute(&mut *conn)?
            }
            None => diesel::sql_query("DELETE FROM chat_pins WHERE chat = ?")
                .bind::<Text, _>(chat)
                .execute(&mut *conn)?,
        };
        Ok(())
    }

    /// # Errors
    /// The store cannot be written.
    pub fn set_archived(&self, chat: &str, archived: bool) -> Result<()> {
        let mut conn = self.lock()?;
        let sql = if archived {
            "INSERT OR IGNORE INTO chat_archives (chat) VALUES (?)"
        } else {
            "DELETE FROM chat_archives WHERE chat = ?"
        };
        diesel::sql_query(sql)
            .bind::<Text, _>(chat)
            .execute(&mut *conn)?;
        Ok(())
    }

    /// Stars or unstars message `id` of `chat`.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_starred(&self, chat: &str, id: &str, starred: bool) -> Result<()> {
        let mut conn = self.lock()?;
        let sql = if starred {
            "INSERT OR IGNORE INTO starred (chat, id) VALUES (?, ?)"
        } else {
            "DELETE FROM starred WHERE chat = ? AND id = ?"
        };
        diesel::sql_query(sql)
            .bind::<Text, _>(chat)
            .bind::<Text, _>(id)
            .execute(&mut *conn)?;
        Ok(())
    }

    /// Starred messages still stored, newest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn starred(&self, limit: i64) -> Result<Vec<Hit>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT m.chat, m.rowid AS seq, m.ts, m.kind, m.body, m.from_me
             FROM starred s JOIN messages m ON m.chat = s.chat AND m.id = s.id
             WHERE m.kind <> 'deleted'
             ORDER BY m.ts DESC, m.rowid DESC LIMIT ?",
        )
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }

    /// The newest stored message of `chat` as (id, from me, timestamp): what
    /// an archive covers.
    ///
    /// # Errors
    /// The query fails.
    pub fn latest(&self, chat: &str) -> Result<Option<(String, bool, i64)>> {
        #[derive(diesel::QueryableByName)]
        struct Latest {
            #[diesel(sql_type = Text)]
            id: String,
            #[diesel(sql_type = Bool)]
            from_me: bool,
            #[diesel(sql_type = BigInt)]
            ts: i64,
        }
        let mut conn = self.lock()?;
        let row: Option<Latest> = diesel::sql_query(
            "SELECT id, from_me, ts FROM messages WHERE chat = ? AND status <> 'pending'
             ORDER BY ts DESC, rowid DESC LIMIT 1",
        )
        .bind::<Text, _>(chat)
        .get_result(&mut *conn)
        .optional()?;
        Ok(row.map(|r| (r.id, r.from_me, r.ts)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Key;

    #[test]
    fn pins_lead_the_list_and_stars_list_their_messages() {
        let base = std::env::temp_dir().join(format!("nimqo-flags-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([8; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let (a, b) = ("62811@s.whatsapp.net", "62812@s.whatsapp.net");
        inbox.enqueue(a, "1", 1, "old").unwrap();
        inbox.enqueue(b, "2", 2, "new").unwrap();
        let order = || -> Vec<String> {
            inbox
                .chats(10)
                .unwrap()
                .into_iter()
                .map(|c| c.chat)
                .collect()
        };
        assert_eq!(order(), [b, a]);
        inbox.set_pinned(a, Some(5)).unwrap();
        assert_eq!(order(), [a, b]);
        inbox.set_pinned(a, None).unwrap();
        assert_eq!(order(), [b, a]);
        inbox.set_archived(b, true).unwrap();
        assert!(inbox.chats(10).unwrap()[0].archived);
        inbox.set_starred(a, "1", true).unwrap();
        assert_eq!(inbox.starred(10).unwrap()[0].body.as_deref(), Some("old"));
        assert!(inbox.messages_before(a, None, 10).unwrap()[0].starred);
        inbox.set_starred(a, "1", false).unwrap();
        assert!(inbox.starred(10).unwrap().is_empty());
        assert_eq!(inbox.latest(a).unwrap(), None, "pending is not covered");
        std::fs::remove_dir_all(&base).unwrap();
    }
}
