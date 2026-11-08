//! Saved contact names, synced from the phone's address book (app state).

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Nullable, Text};

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

    /// Everyone in the address book, as stored (by number, or by LID when
    /// the number is unknown).
    ///
    /// # Errors
    /// The query fails.
    pub fn contact_jids(&self) -> Result<Vec<String>> {
        #[derive(diesel::QueryableByName)]
        struct J {
            #[diesel(sql_type = Text)]
            jid: String,
        }
        let mut conn = self.lock()?;
        let rows: Vec<J> = diesel::sql_query("SELECT jid FROM contacts").load(&mut *conn)?;
        Ok(rows.into_iter().map(|r| r.jid).collect())
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

    /// Who "@`user`" in a message is: their saved name, else "~" and the
    /// name they chose, else "+" and a LID's number; `user` is a phone
    /// number or a LID, as mentions carry either.
    ///
    /// # Errors
    /// The query fails.
    pub fn mention_name(&self, user: &str) -> Result<Option<String>> {
        #[derive(diesel::QueryableByName)]
        struct Names {
            #[diesel(sql_type = Nullable<Text>)]
            saved: Option<String>,
            #[diesel(sql_type = Nullable<Text>)]
            push: Option<String>,
            #[diesel(sql_type = Nullable<Text>)]
            pn: Option<String>,
        }
        let mut conn = self.lock()?;
        // ponytail: the sender_name fallback scans messages; index sender if
        // pages with many mentions get slow.
        let n: Names = diesel::sql_query(
            "WITH ids(j) AS (SELECT ?1 UNION SELECT ?2
               UNION SELECT pn FROM lid_map WHERE lid = ?2
               UNION SELECT lid FROM lid_map WHERE pn = ?1)
             SELECT coalesce((SELECT name FROM contacts WHERE jid IN (SELECT j FROM ids) LIMIT 1),
                             (SELECT name FROM chat_names WHERE chat IN (SELECT j FROM ids) LIMIT 1)) AS saved,
                    coalesce((SELECT nullif(name, '') FROM push_names
                              WHERE jid IN (SELECT j FROM ids) LIMIT 1),
                             (SELECT sender_name FROM messages WHERE sender IN (SELECT j FROM ids)
                              AND sender_name <> '' ORDER BY ts DESC LIMIT 1)) AS push,
                    -- Only a LID's known number: an unknown one stays as typed.
                    (SELECT pn FROM lid_map WHERE lid = ?2) AS pn",
        )
        .bind::<Text, _>(format!("{user}@s.whatsapp.net"))
        .bind::<Text, _>(format!("{user}@lid"))
        .get_result(&mut *conn)?;
        Ok(n.saved.or(n.push.map(|p| format!("~{p}"))).or(n
            .pn
            .and_then(|p| p.split('@').next().map(|d| format!("+{d}")))))
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

    #[test]
    fn mentions_name_people_by_number_or_lid() {
        let path = std::env::temp_dir().join(format!("nimqo-mentions-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([7; 32]), Fault::None).unwrap();
        assert_eq!(inbox.mention_name("178").unwrap(), None);
        inbox
            .record_lids(&[("178@lid".into(), "62811@s.whatsapp.net".into())])
            .unwrap();
        assert_eq!(
            inbox.mention_name("178").unwrap().as_deref(),
            Some("+62811")
        );
        inbox
            .record_push_names(&[("178@lid".into(), "Bo".into())])
            .unwrap();
        assert_eq!(inbox.mention_name("178").unwrap().as_deref(), Some("~Bo"));
        inbox.save_contact("62811@s.whatsapp.net", "Bob").unwrap();
        assert_eq!(inbox.mention_name("178").unwrap().as_deref(), Some("Bob"));
        assert_eq!(inbox.mention_name("62811").unwrap().as_deref(), Some("Bob"));
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
