//! Muted chats, as set on any of the account's devices: no notification
//! and no count on the Dock for them.

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Text};

use crate::inbox::Inbox;

/// `until` for a chat muted with no end.
pub const FOREVER: i64 = -1;

impl Inbox {
    /// Mutes `chat` until `until` (milliseconds since 1970, or `FOREVER`);
    /// 0 unmutes it.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_mute(&self, chat: &str, until: i64) -> Result<()> {
        let mut conn = self.lock()?;
        if until == 0 {
            diesel::sql_query("DELETE FROM chat_mutes WHERE chat = ?")
                .bind::<Text, _>(chat)
                .execute(&mut *conn)?;
        } else {
            diesel::sql_query("INSERT OR REPLACE INTO chat_mutes (chat, until) VALUES (?, ?)")
                .bind::<Text, _>(chat)
                .bind::<BigInt, _>(until)
                .execute(&mut *conn)?;
        }
        Ok(())
    }

    /// True the first time it is asked for `task`, ever, on this store.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn first_time(&self, task: &str) -> Result<bool> {
        let mut conn = self.lock()?;
        Ok(
            diesel::sql_query("INSERT OR IGNORE INTO done_once (task) VALUES (?)")
                .bind::<Text, _>(task)
                .execute(&mut *conn)?
                == 1,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Key;

    #[test]
    fn a_mute_holds_until_its_end() {
        let base = std::env::temp_dir().join(format!("nimqo-mute-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([7; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let (a, b) = ("62811@s.whatsapp.net", "62812@s.whatsapp.net");
        inbox.insert_kind_for_test(a, "1", "text", Vec::new());
        inbox.insert_kind_for_test(b, "2", "text", Vec::new());
        let muted = |chat: &str| {
            inbox
                .chats(10)
                .unwrap()
                .into_iter()
                .find(|c| c.chat == chat)
                .unwrap()
                .muted
        };
        assert!(!muted(a));
        inbox.set_mute(a, FOREVER).unwrap();
        inbox.set_mute(b, 1).unwrap(); // ended long ago
        assert!(muted(a) && !muted(b));
        inbox.set_mute(a, 0).unwrap();
        assert!(!muted(a));
        assert!(inbox.first_time("x").unwrap() && !inbox.first_time("x").unwrap());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
