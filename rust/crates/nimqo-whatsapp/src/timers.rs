//! Disappearing messages: deleted from this Mac when their time is up, the
//! way the phone deletes them.

use anyhow::Result;
use diesel::sql_types::{BigInt, Text};
use diesel::{Connection, RunQueryDsl};

use crate::inbox::Inbox;

impl Inbox {
    /// Sets a chat's disappearing-message timer; 0 turns it off.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_timer(&self, chat: &str, seconds: u32) -> Result<()> {
        let timer = crate::effects::Effect::Timer {
            chat: chat.to_owned(),
            seconds,
        };
        self.commit(Vec::new(), &[timer])
    }

    /// Deletes messages whose time is up, with their reactions. Returns the
    /// chats that changed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn purge_expired(&self, now: i64) -> Result<Vec<String>> {
        #[derive(diesel::QueryableByName)]
        struct C {
            #[diesel(sql_type = Text)]
            chat: String,
        }
        let mut conn = self.lock()?;
        let mut chats: Vec<String> = conn
            .transaction(|c| {
                // Reactions are keyed by (chat, id) only, so another sender's
                // timed message reusing an id must not take a kept message's
                // reactions with it: drop them only when no message keeps them.
                diesel::sql_query(
                    "DELETE FROM reactions
                     WHERE EXISTS (SELECT 1 FROM messages m
                       WHERE m.chat = reactions.chat AND m.id = reactions.target
                         AND m.expires_at <= ? AND m.status <> 'pending')
                     AND NOT EXISTS (SELECT 1 FROM messages k
                       WHERE k.chat = reactions.chat AND k.id = reactions.target
                         AND (k.expires_at IS NULL OR k.expires_at > ?
                              OR k.status = 'pending'))",
                )
                .bind::<BigInt, _>(now)
                .bind::<BigInt, _>(now)
                .execute(c)?;
                // Unsent own messages stay until sent; the phone counts from then.
                diesel::sql_query(
                    "DELETE FROM messages WHERE expires_at <= ? AND status <> 'pending'
                 RETURNING chat",
                )
                .bind::<BigInt, _>(now)
                .load::<C>(c)
            })?
            .into_iter()
            .map(|c| c.chat)
            .collect();
        chats.sort_unstable();
        chats.dedup();
        Ok(chats)
    }
}

#[cfg(test)]
mod tests {
    use crate::inbox::{Fault, Inbox};
    use crate::vault::Key;

    #[test]
    fn timed_messages_go_when_due_and_follow_the_chat_timer() {
        let path = std::env::temp_dir().join(format!("nimqo-timers-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([9; 32]), Fault::None).unwrap();
        let a = "62811@s.whatsapp.net";
        inbox.insert_timed_for_test(a, "old", Some(100));
        inbox.insert_timed_for_test(a, "keep", None);
        // The chat timer is set: own messages queued now carry it.
        inbox.apply_for_test(&[crate::effects::Effect::Timer {
            chat: a.into(),
            seconds: 60,
        }]);
        inbox.enqueue(a, "mine", 1000, "hi").unwrap();
        assert_eq!(inbox.pending().unwrap()[0].timer, Some(60));

        assert_eq!(inbox.purge_expired(99).unwrap(), Vec::<String>::new());
        assert_eq!(inbox.purge_expired(100).unwrap(), [a]);
        assert_eq!(
            inbox.purge_expired(5000).unwrap(),
            Vec::<String>::new(),
            "pending stays"
        );
        let ids: Vec<_> = inbox
            .messages(a, 10)
            .unwrap()
            .into_iter()
            .map(|m| m.id)
            .collect();
        assert_eq!(ids, ["keep", "mine"]);

        // In a group, a timed message reusing a kept message's id does not
        // take that message's reactions when it expires.
        let g = "1-2@g.us";
        inbox.insert_for_test(g, "victim@s.whatsapp.net", "x");
        inbox.insert_timed_for_test(g, "x", Some(200)); // another sender, same id
        inbox.apply_for_test(&[crate::effects::Effect::React {
            chat: g.into(),
            reactor: "r@s.whatsapp.net".into(),
            target: "x".into(),
            emoji: Some("👍".into()),
        }]);
        inbox.purge_expired(300).unwrap();
        let kept = inbox.messages(g, 10).unwrap();
        assert_eq!(kept.len(), 1);
        assert_eq!(kept[0].reactions.as_deref(), Some("👍"));
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
