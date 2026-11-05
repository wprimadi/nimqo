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
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
