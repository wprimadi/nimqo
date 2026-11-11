//! Who got, read, and played each own message, and when: what Message
//! Info shows. Kept per recipient, from their receipts; a read counts as
//! delivered too, a play as read.

use anyhow::Result;
use diesel::sql_types::{BigInt, Nullable, Text};
use diesel::{OptionalExtension, RunQueryDsl};

use crate::inbox::{Inbox, ME};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Seen {
    Delivered,
    Read,
    Played,
}

#[derive(Debug, Clone, PartialEq, Eq, diesel::QueryableByName)]
pub struct Recipient {
    #[diesel(sql_type = Text)]
    pub who: String,
    #[diesel(sql_type = Nullable<BigInt>)]
    pub delivered: Option<i64>,
    #[diesel(sql_type = Nullable<BigInt>)]
    pub read: Option<i64>,
    #[diesel(sql_type = Nullable<BigInt>)]
    pub played: Option<i64>,
}

impl Inbox {
    /// Notes that `who` (a chat id) `seen` own message `id` in `chat` at
    /// `ts`; the first time of each counts, and none before it was sent.
    /// Only for an own message of that chat, and in a one-to-one chat only
    /// from the other side: a receipt cannot speak for another chat.
    /// Returns whether it was kept.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn record_receipt(
        &self,
        chat: &str,
        id: &str,
        who: &str,
        seen: Seen,
        ts: i64,
    ) -> Result<bool> {
        #[derive(diesel::QueryableByName)]
        struct Sent {
            #[diesel(sql_type = BigInt)]
            ts: i64,
        }
        if !chat.ends_with("@g.us") && who != chat {
            return Ok(false);
        }
        let mut conn = self.lock()?;
        let Some(Sent { ts: sent }) = diesel::sql_query(
            "SELECT ts FROM messages WHERE chat = ? AND sender = ? AND id = ? LIMIT 1",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(ME)
        .bind::<Text, _>(id)
        .get_result(&mut *conn)
        .optional()?
        else {
            return Ok(false);
        };
        let ts = ts.max(sent);
        let at = |level: Seen| (seen as u8 >= level as u8).then_some(ts);
        diesel::sql_query(
            "INSERT INTO receipts (chat, id, who, delivered, read, played) VALUES (?, ?, ?, ?, ?, ?)
             ON CONFLICT (chat, id, who) DO UPDATE SET
               delivered = coalesce(delivered, excluded.delivered),
               read = coalesce(read, excluded.read),
               played = coalesce(played, excluded.played)",
        )
        .bind::<Text, _>(chat)
        .bind::<Text, _>(id)
        .bind::<Text, _>(who)
        .bind::<Nullable<BigInt>, _>(at(Seen::Delivered))
        .bind::<Nullable<BigInt>, _>(at(Seen::Read))
        .bind::<Nullable<BigInt>, _>(at(Seen::Played))
        .execute(&mut *conn)?;
        Ok(true)
    }

    /// The recipients of own message `seq` in `chat`, as their receipts
    /// came: read first, then delivered.
    ///
    /// # Errors
    /// The store cannot be read.
    pub fn recipients(&self, chat: &str, seq: i64) -> Result<Vec<Recipient>> {
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT r.who, r.delivered, r.read, r.played FROM receipts r
             JOIN messages m ON m.chat = r.chat AND m.id = r.id AND m.sender = ?
             WHERE m.rowid = ? AND m.chat = ?
             ORDER BY r.read IS NULL, r.read, r.delivered LIMIT 1100",
        )
        .bind::<Text, _>(ME)
        .bind::<BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .load(&mut *conn)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Key;

    #[test]
    fn each_recipient_keeps_the_first_time_of_each_step() {
        let base = std::env::temp_dir().join(format!("nimqo-receipts-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([7; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let group = "1203@g.us";
        inbox.insert_for_test(group, ME, "m1");
        let (ana, bo) = ("62811@s.whatsapp.net", "62812@s.whatsapp.net");
        assert!(
            !inbox
                .record_receipt(group, "nope", ana, Seen::Read, 1)
                .unwrap(),
            "not ours"
        );
        assert!(
            !inbox
                .record_receipt("9@g.us", "m1", ana, Seen::Read, 1)
                .unwrap(),
            "another chat"
        );
        inbox.insert_for_test(ana, ME, "d1");
        assert!(
            !inbox.record_receipt(ana, "d1", bo, Seen::Read, 1).unwrap(),
            "not the other side"
        );
        assert!(
            inbox
                .record_receipt(group, "m1", ana, Seen::Delivered, 10)
                .unwrap()
        );
        inbox
            .record_receipt(group, "m1", ana, Seen::Read, 20)
            .unwrap();
        inbox
            .record_receipt(group, "m1", ana, Seen::Delivered, 30)
            .unwrap();
        inbox
            .record_receipt(group, "m1", bo, Seen::Read, 15)
            .unwrap();
        let seq = inbox.messages(group, 1).unwrap()[0].seq;
        let all = inbox.recipients(group, seq).unwrap();
        assert_eq!(all.len(), 2);
        // Bo read first; a read counts as delivered.
        assert_eq!(
            (all[0].who.as_str(), all[0].delivered, all[0].read),
            (bo, Some(15), Some(15))
        );
        assert_eq!(
            (all[1].delivered, all[1].read, all[1].played),
            (Some(10), Some(20), None)
        );
    }
}
