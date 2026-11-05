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
             UNION SELECT sender AS jid FROM messages WHERE sender LIKE '%@lid'",
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
            Ok::<_, diesel::result::Error>(())
        })?;
        Ok(vec![lid.to_owned(), pn.to_owned()])
    }
}

/// Merges every stored LID whose phone number upstream now knows, then tells
/// the app which chats changed.
pub async fn resolve(inbox: &Inbox, client: &Client) {
    let users = match inbox.lid_users() {
        Ok(u) => u,
        Err(e) => return log::warn!("LID lookup failed: {e:#}"),
    };
    let mut changed = Vec::new();
    for user in users {
        let Ok(Some(entry)) = client.get_lid_pn_entry(&Jid::lid(user.as_str())).await else {
            continue;
        };
        let (lid, pn) = (
            Jid::lid(user.as_str()).to_string(),
            Jid::pn(&*entry.phone_number).to_string(),
        );
        match inbox.merge_lid(&lid, &pn) {
            Ok(chats) => changed.extend(chats),
            Err(e) => log::warn!("LID merge failed: {e:#}"),
        }
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
        assert_eq!(inbox.lid_users().unwrap(), ["77"]);

        inbox.merge_lid(lid, pn).unwrap();
        let chats: Vec<_> = inbox
            .chats(10)
            .unwrap()
            .into_iter()
            .map(|c| c.chat)
            .collect();
        assert_eq!(chats, [pn]);
        assert_eq!(inbox.count().unwrap(), 2);
        assert_eq!(inbox.lid_users().unwrap(), Vec::<String>::new());
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
