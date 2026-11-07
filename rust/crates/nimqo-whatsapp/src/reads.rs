//! Read state of received messages. Local only: sending read receipts is
//! the caller's decision (during development, only for the test chat).

use crate::inbox::{Inbox, STATUS};
use anyhow::Result;
use diesel::sql_types::Text;
use diesel::{Connection, RunQueryDsl};

#[derive(diesel::QueryableByName)]
pub struct Unread {
    #[diesel(sql_type = Text)]
    pub sender: String,
    #[diesel(sql_type = Text)]
    pub id: String,
}

impl Inbox {
    /// Marks status update `seq` viewed; returns it when it was not, so the
    /// caller can tell its poster once.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn view_status(&self, seq: i64) -> Result<Option<Unread>> {
        let mut conn = self.lock()?;
        Ok(diesel::OptionalExtension::optional(
            diesel::sql_query(
                "UPDATE messages SET read = 1
                 WHERE chat = ? AND rowid = ? AND from_me = 0 AND read = 0
                 RETURNING sender, id",
            )
            .bind::<Text, _>(STATUS)
            .bind::<diesel::sql_types::BigInt, _>(seq)
            .get_result(&mut *conn),
        )?)
    }

    /// Status updates (seqs) not viewed yet.
    ///
    /// # Errors
    /// The query fails.
    pub fn unviewed_statuses(&self) -> Result<Vec<i64>> {
        #[derive(diesel::QueryableByName)]
        struct Seq {
            #[diesel(sql_type = diesel::sql_types::BigInt)]
            seq: i64,
        }
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT rowid AS seq FROM messages WHERE chat = ? AND from_me = 0 AND read = 0",
        )
        .bind::<Text, _>(STATUS)
        .load::<Seq>(&mut *conn)?
        .into_iter()
        .map(|s| s.seq)
        .collect())
    }

    /// Marks every received message in `chat` read and returns them, so the
    /// caller can send receipts for exactly these.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn mark_chat_read(&self, chat: &str) -> Result<Vec<Unread>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "UPDATE messages SET read = 1 WHERE chat = ? AND from_me = 0 AND read = 0
             RETURNING sender, id",
        )
        .bind::<Text, _>(chat)
        .load(&mut *conn)?)
    }

    /// The phone marked `chat` read up to `through` (a timestamp), or all
    /// of it. Returns whether anything changed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn read_through(&self, chat: &str, through: Option<i64>) -> Result<bool> {
        let mut conn = self.lock()?;
        let n = diesel::sql_query(
            "UPDATE messages SET read = 1
             WHERE chat = ? AND from_me = 0 AND read = 0 AND ts <= ?",
        )
        .bind::<Text, _>(chat)
        .bind::<diesel::sql_types::BigInt, _>(through.unwrap_or(i64::MAX))
        .execute(&mut *conn)?;
        Ok(n > 0)
    }

    /// Messages read on another of the account's devices (read-self
    /// receipts). Returns whether anything changed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn read_elsewhere(&self, chat: &str, ids: &[&str]) -> Result<bool> {
        let mut conn = self.lock()?;
        let changed = conn.transaction(|c| {
            let mut n = 0;
            for id in ids {
                n += diesel::sql_query(
                    "UPDATE messages SET read = 1 WHERE chat = ? AND id = ? AND from_me = 0",
                )
                .bind::<Text, _>(chat)
                .bind::<Text, _>(*id)
                .execute(c)?;
            }
            Ok::<_, diesel::result::Error>(n)
        })?;
        Ok(changed > 0)
    }
}

#[cfg(test)]
mod tests {
    use crate::inbox::{Fault, Inbox};
    use crate::vault::Key;

    #[test]
    fn opening_a_chat_reads_only_its_unread_messages_once() {
        let path = std::env::temp_dir().join(format!("nimqo-reads-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([6; 32]), Fault::None).unwrap();
        let (a, b) = ("a@s.whatsapp.net", "b@s.whatsapp.net");
        inbox.insert_for_test(a, a, "m1");
        inbox.insert_for_test(a, a, "m2");
        inbox.insert_for_test(b, b, "m3");
        let unread = |c: &str| {
            inbox
                .chats(10)
                .unwrap()
                .into_iter()
                .find(|r| r.chat == c)
                .unwrap()
                .unread
        };
        assert_eq!((unread(a), unread(b)), (2, 1));

        assert_eq!(inbox.mark_chat_read(a).unwrap().len(), 2);
        assert_eq!(
            inbox.mark_chat_read(a).unwrap().len(),
            0,
            "no second receipt"
        );
        assert_eq!((unread(a), unread(b)), (0, 1));

        // Read on the phone: by receipt ids, or the whole chat up to a time.
        inbox.insert_for_test(b, b, "m4");
        assert!(inbox.read_elsewhere(b, &["m3"]).unwrap());
        assert_eq!(unread(b), 1);
        assert!(inbox.read_through(b, None).unwrap());
        assert!(!inbox.read_through(b, None).unwrap());
        assert_eq!(unread(b), 0);
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
