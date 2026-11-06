//! Saved contact names, synced from the phone's address book (app state).

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Text};

use crate::inbox::Inbox;

impl Inbox {
    /// Saves or renames a contact; an empty name removes it.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn save_contact(&self, jid: &str, name: &str) -> Result<()> {
        let mut conn = self.lock()?;
        let name = name.trim();
        if name.is_empty() {
            diesel::sql_query("DELETE FROM contacts WHERE jid = ?")
                .bind::<Text, _>(jid)
                .execute(&mut *conn)?;
        } else {
            diesel::sql_query("INSERT OR REPLACE INTO contacts (jid, name) VALUES (?, ?)")
                .bind::<Text, _>(jid)
                .bind::<Text, _>(name)
                .execute(&mut *conn)?;
        }
        Ok(())
    }

    /// # Errors
    /// The query fails.
    pub fn contact_count(&self) -> Result<i64> {
        #[derive(diesel::QueryableByName)]
        struct N {
            #[diesel(sql_type = BigInt)]
            n: i64,
        }
        let mut conn = self.lock()?;
        let rows: Vec<N> =
            diesel::sql_query("SELECT COUNT(*) AS n FROM contacts").load(&mut *conn)?;
        Ok(rows.first().map_or(0, |r| r.n))
    }

    /// Profile names from history (self-chosen, shown marked as such).
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn record_push_names(&self, names: &[(String, String)]) -> Result<()> {
        let mut conn = self.lock()?;
        diesel::Connection::transaction(&mut *conn, |c| {
            for (jid, name) in names {
                diesel::sql_query("INSERT OR REPLACE INTO push_names (jid, name) VALUES (?, ?)")
                    .bind::<Text, _>(jid)
                    .bind::<Text, _>(name.trim())
                    .execute(c)?;
            }
            Ok::<_, diesel::result::Error>(())
        })?;
        Ok(())
    }

    /// Diagnostics, counts only: saved names, how many are keyed by LID,
    /// and how many name a stored 1:1 chat.
    ///
    /// # Errors
    /// The query fails.
    pub fn contact_stats(&self) -> Result<(i64, i64, i64, i64, i64, i64)> {
        #[derive(diesel::QueryableByName)]
        struct S {
            #[diesel(sql_type = BigInt)]
            total: i64,
            #[diesel(sql_type = BigInt)]
            by_lid: i64,
            #[diesel(sql_type = BigInt)]
            matched: i64,
            #[diesel(sql_type = BigInt)]
            by_pn: i64,
            #[diesel(sql_type = BigInt)]
            direct: i64,
            #[diesel(sql_type = BigInt)]
            pushed: i64,
        }
        let mut conn = self.lock()?;
        let s: S = diesel::sql_query(
            "SELECT COUNT(*) AS total,
               COALESCE(SUM(jid LIKE '%@lid'), 0) AS by_lid,
               COALESCE(SUM(EXISTS (SELECT 1 FROM messages WHERE chat = contacts.jid)), 0)
                 AS matched,
               COALESCE(SUM(jid LIKE '%@s.whatsapp.net'), 0) AS by_pn,
               (SELECT COUNT(DISTINCT chat) FROM messages
                WHERE chat NOT LIKE '%@g.us' AND chat NOT LIKE '%@newsletter') AS direct,
               (SELECT COUNT(DISTINCT chat) FROM messages
                WHERE chat NOT LIKE '%@g.us' AND from_me = 0 AND sender_name <> '') AS pushed
             FROM contacts",
        )
        .get_result(&mut *conn)?;
        Ok((s.total, s.by_lid, s.matched, s.by_pn, s.direct, s.pushed))
    }
}

#[cfg(test)]
mod tests {
    use crate::inbox::{Fault, Inbox};
    use crate::vault::Key;

    #[test]
    fn saved_names_show_on_chats_and_senders_and_can_be_removed() {
        let path = std::env::temp_dir().join(format!("nimqo-contacts-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([7; 32]), Fault::None).unwrap();
        let a = "62811@s.whatsapp.net";
        inbox.insert_for_test(a, a, "m1");
        inbox.save_contact(a, " Ana ").unwrap();
        assert_eq!(
            inbox.chats(10).unwrap()[0].contact_name.as_deref(),
            Some("Ana")
        );
        assert_eq!(
            inbox.messages(a, 10).unwrap()[0].contact_name.as_deref(),
            Some("Ana")
        );
        assert_eq!(inbox.contact_count().unwrap(), 1);
        inbox.save_contact(a, "").unwrap();
        assert_eq!(inbox.chats(10).unwrap()[0].contact_name, None);
        // Not in the address book: the profile name from history, found by
        // number or through the LID the history used.
        inbox
            .record_push_names(&[("77@lid".into(), "Ana P".into())])
            .unwrap();
        assert_eq!(inbox.chats(10).unwrap()[0].name, None);
        inbox.record_lids(&[("77@lid".into(), a.into())]).unwrap();
        assert_eq!(inbox.chats(10).unwrap()[0].name.as_deref(), Some("Ana P"));
        inbox
            .record_push_names(&[(a.into(), "Ana N".into())])
            .unwrap();
        assert_eq!(inbox.chats(10).unwrap()[0].name.as_deref(), Some("Ana N"));
        // The name the phone shows, from history, counts as saved.
        inbox.import(a, Some("Ana H".into()), Vec::new()).unwrap();
        assert_eq!(
            inbox.chats(10).unwrap()[0].contact_name.as_deref(),
            Some("Ana H")
        );
        assert_eq!(
            inbox.messages(a, 10).unwrap()[0].contact_name.as_deref(),
            Some("Ana H")
        );
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
