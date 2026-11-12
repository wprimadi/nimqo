//! LID resolution: WhatsApp addresses many contacts by LID (an alias) and
//! not every message carries the phone number. Once upstream has learned a
//! LID's number, the chats and senders stored under the LID are merged into
//! the phone-number ones, so a contact is one chat, not two.

use anyhow::Result;
use diesel::sql_types::Text;
use diesel::{Connection, RunQueryDsl};
use whatsapp_rust::{Client, Jid};

use crate::inbox::Inbox;

impl Inbox {
    /// Remembers LID -> phone number pairs (from history).
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn record_lids(&self, pairs: &[(String, String)]) -> Result<()> {
        let mut conn = self.lock()?;
        conn.transaction(|c| {
            for (lid, pn) in pairs {
                diesel::sql_query("INSERT OR REPLACE INTO lid_map (lid, pn) VALUES (?, ?)")
                    .bind::<Text, _>(lid)
                    .bind::<Text, _>(pn)
                    .execute(c)?;
            }
            Ok::<_, diesel::result::Error>(())
        })?;
        Ok(())
    }

    /// `jid` and the other address it is known by (number <-> LID).
    ///
    /// # Errors
    /// The query fails.
    pub fn aliases(&self, jid: &str) -> Result<Vec<String>> {
        #[derive(diesel::QueryableByName)]
        struct A {
            #[diesel(sql_type = Text)]
            jid: String,
        }
        let mut conn = self.lock()?;
        let rows: Vec<A> = diesel::sql_query(
            "SELECT ?1 AS jid UNION SELECT pn FROM lid_map WHERE lid = ?1
             UNION SELECT lid FROM lid_map WHERE pn = ?1",
        )
        .bind::<Text, _>(jid)
        .load(&mut *conn)?;
        Ok(rows.into_iter().map(|a| a.jid).collect())
    }

    pub(crate) fn known_pn(&self, lid: &str) -> Result<Option<String>> {
        #[derive(diesel::QueryableByName)]
        struct P {
            #[diesel(sql_type = Text)]
            pn: String,
        }
        let mut conn = self.lock()?;
        let rows: Vec<P> = diesel::sql_query("SELECT pn FROM lid_map WHERE lid = ?")
            .bind::<Text, _>(lid)
            .load(&mut *conn)?;
        Ok(rows.into_iter().next().map(|p| p.pn))
    }

    /// Distinct LID users still stored as a chat or a sender.
    ///
    /// # Errors
    /// The query fails.
    pub fn lid_users(&self) -> Result<Vec<String>> {
        #[derive(diesel::QueryableByName)]
        struct U {
            #[diesel(sql_type = Text)]
            jid: String,
        }
        let mut conn = self.lock()?;
        let rows: Vec<U> = diesel::sql_query(
            "SELECT chat AS jid FROM messages WHERE chat LIKE '%@lid'
             UNION SELECT sender AS jid FROM messages WHERE sender LIKE '%@lid'
             UNION SELECT jid FROM contacts WHERE jid LIKE '%@lid'",
        )
        .load(&mut *conn)?;
        Ok(rows
            .into_iter()
            .filter_map(|u| u.jid.strip_suffix("@lid").map(str::to_owned))
            .collect())
    }

    /// Moves everything stored under `lid` to `pn`. A row that already exists
    /// under `pn` is the same message seen twice, so the LID copy is dropped.
    /// Returns the chats that changed.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn merge_lid(&self, lid: &str, pn: &str) -> Result<Vec<String>> {
        let mut conn = self.lock()?;
        conn.transaction(|c| {
            for column in ["chat", "sender"] {
                diesel::sql_query(format!(
                    "UPDATE OR IGNORE messages SET {column} = ? WHERE {column} = ?"
                ))
                .bind::<Text, _>(pn)
                .bind::<Text, _>(lid)
                .execute(c)?;
                diesel::sql_query(format!("DELETE FROM messages WHERE {column} = ?"))
                    .bind::<Text, _>(lid)
                    .execute(c)?;
            }
            // Per-chat state stored under the LID follows; the number wins.
            for table in ["chat_timers", "chat_mutes", "reactions"] {
                diesel::sql_query(format!(
                    "UPDATE OR IGNORE {table} SET chat = ? WHERE chat = ?"
                ))
                .bind::<Text, _>(pn)
                .bind::<Text, _>(lid)
                .execute(c)?;
                diesel::sql_query(format!("DELETE FROM {table} WHERE chat = ?"))
                    .bind::<Text, _>(lid)
                    .execute(c)?;
            }
            // A name synced before the number was known.
            diesel::sql_query("UPDATE OR IGNORE contacts SET jid = ? WHERE jid = ?")
                .bind::<Text, _>(pn)
                .bind::<Text, _>(lid)
                .execute(c)?;
            diesel::sql_query("DELETE FROM contacts WHERE jid = ?")
                .bind::<Text, _>(lid)
                .execute(c)?;
            Ok::<_, diesel::result::Error>(())
        })?;
        Ok(vec![lid.to_owned(), pn.to_owned()])
    }
}

/// The chat id messages are stored under: a LID 1:1 chat becomes its phone
/// number when known (see `merge_lid`); anything else loses its device.
pub async fn phone_chat(inbox: &Inbox, client: &Client, jid: &Jid) -> String {
    let plain = jid.to_non_ad_string();
    if !jid.is_lid() {
        return plain;
    }
    if let Ok(Some(pn)) = inbox.known_pn(&plain) {
        return pn;
    }
    match client.get_lid_pn_entry(jid).await {
        Ok(Some(entry)) => Jid::pn(&*entry.phone_number).to_string(),
        _ => plain,
    }
}

/// Merges every stored LID whose phone number upstream now knows, then tells
/// the app which chats changed.
pub async fn resolve(inbox: &Inbox, client: &Client) {
    let users = match inbox.lid_users() {
        Ok(u) => u,
        Err(e) => return log::warn!("LID lookup failed: {e:#}"),
    };
    let (mut changed, mut unknown) = (Vec::new(), 0);
    for user in users {
        let lid = Jid::lid(user.as_str()).to_string();
        let pn = match inbox.known_pn(&lid) {
            Ok(Some(pn)) => pn,
            _ => {
                if let Ok(Some(entry)) = client.get_lid_pn_entry(&Jid::lid(user.as_str())).await {
                    Jid::pn(&*entry.phone_number).to_string()
                } else {
                    unknown += 1;
                    continue;
                }
            }
        };
        match inbox.merge_lid(&lid, &pn) {
            Ok(chats) => changed.extend(chats),
            Err(e) => log::warn!("LID merge failed: {e:#}"),
        }
    }
    if unknown > 0 {
        log::info!("{unknown} LID address(es) without a known phone number yet");
    }
    if !changed.is_empty() {
        log::info!(
            "merged {} LID address(es) into phone numbers",
            changed.len() / 2
        );
        changed.sort_unstable();
        changed.dedup();
        inbox.notify(changed);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::Fault;
    use crate::vault::Key;

    #[test]
    fn a_lid_chat_merges_into_the_phone_chat_without_duplicates() {
        let path = std::env::temp_dir().join(format!("nimqo-lids-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([5; 32]), Fault::None).unwrap();
        let (lid, pn) = ("77@lid", "62811@s.whatsapp.net");
        // Same message under both addresses, plus one only under the LID.
        inbox.insert_for_test(lid, lid, "m1");
        inbox.insert_for_test(lid, lid, "m2");
        inbox.insert_for_test(pn, pn, "m1");
        // The address book synced before the number was known.
        inbox.save_contact(lid, "Ana").unwrap();
        assert_eq!(inbox.lid_users().unwrap(), ["77"]);
        inbox.record_lids(&[(lid.into(), pn.into())]).unwrap();
        assert_eq!(inbox.known_pn(lid).unwrap().as_deref(), Some(pn));

        inbox.apply_for_test(&[crate::effects::Effect::Timer {
            chat: lid.into(),
            seconds: 0,
        }]);
        inbox.merge_lid(lid, pn).unwrap();
        let chats: Vec<_> = inbox
            .chats(10)
            .unwrap()
            .into_iter()
            .map(|c| c.chat)
            .collect();
        assert_eq!(chats, [pn]);
        assert_eq!(
            inbox.chats(10).unwrap()[0].contact_name.as_deref(),
            Some("Ana"),
            "the saved name follows the number"
        );
        assert_eq!(
            inbox.chats(10).unwrap()[0].timer,
            0,
            "timer moved, no LID row left"
        );
        assert_eq!(inbox.count().unwrap(), 2);
        assert_eq!(inbox.lid_users().unwrap(), Vec::<String>::new());
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
