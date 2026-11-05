//! Read state of received messages. Local only: sending read receipts is
//! the caller's decision (during development, only for the test chat).

use anyhow::Result;
use diesel::sql_types::Text;
use diesel::{Connection, RunQueryDsl};
use whatsapp_rust::types::message::MessageSource;

use crate::inbox::{Inbox, chat_key};

#[derive(diesel::QueryableByName)]
pub struct Unread {
    #[diesel(sql_type = Text)]
    pub sender: String,
    #[diesel(sql_type = Text)]
    pub id: String,
}

impl Inbox {
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

    /// Messages read on another of the account's devices. Returns the chat
    /// when anything changed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn read_elsewhere(&self, src: &MessageSource, ids: &[&str]) -> Result<Option<String>> {
        let chat = chat_key(src);
        let mut conn = self.lock()?;
        let changed = conn.transaction(|c| {
            let mut n = 0;
            for id in ids {
                n += diesel::sql_query(
                    "UPDATE messages SET read = 1 WHERE chat = ? AND id = ? AND from_me = 0",
                )
                .bind::<Text, _>(&chat)
                .bind::<Text, _>(*id)
                .execute(c)?;
            }
            Ok::<_, diesel::result::Error>(n)
        })?;
        Ok((changed > 0).then_some(chat))
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
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
