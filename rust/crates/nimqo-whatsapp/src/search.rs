//! Local search over stored message text: nothing leaves the Mac.
//!
//! ponytail: a LIKE scan (case-insensitive for ASCII only); an FTS5 index
//! when large stores make it slow or other scripts need folding.

use anyhow::Result;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Bool, Nullable, Text};

use crate::inbox::Inbox;

#[derive(Debug, diesel::QueryableByName)]
pub struct Hit {
    #[diesel(sql_type = Text)]
    pub chat: String,
    #[diesel(sql_type = BigInt)]
    pub seq: i64,
    #[diesel(sql_type = BigInt)]
    pub ts: i64,
    #[diesel(sql_type = Text)]
    pub kind: String,
    #[diesel(sql_type = Nullable<Text>)]
    pub body: Option<String>,
    #[diesel(sql_type = Bool)]
    pub from_me: bool,
}

/// `text` as a LIKE pattern matching it anywhere, wildcards escaped.
fn pattern(text: &str) -> String {
    let escaped: String = text
        .chars()
        .flat_map(|c| match c {
            '%' | '_' | '\\' => vec!['\\', c],
            c => vec![c],
        })
        .collect();
    format!("%{escaped}%")
}

impl Inbox {
    /// Messages whose text or caption contains `text`, newest first.
    ///
    /// # Errors
    /// The query fails.
    pub fn search(&self, text: &str, limit: i64) -> Result<Vec<Hit>> {
        let text = text.trim();
        if text.is_empty() {
            return Ok(Vec::new());
        }
        let mut conn = self.lock()?;
        Ok(diesel::sql_query(
            "SELECT chat, rowid AS seq, ts, kind, body, from_me FROM messages
             WHERE body LIKE ? ESCAPE '\\' AND chat <> 'status@broadcast' AND kind NOT IN ('deleted', 'document', 'call')
             ORDER BY ts DESC, rowid DESC LIMIT ?",
        )
        .bind::<Text, _>(pattern(text))
        .bind::<BigInt, _>(limit)
        .load(&mut *conn)?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::Fault;
    use crate::vault::Key;

    #[test]
    fn finds_text_case_insensitively_and_wildcards_are_literal() {
        let path = std::env::temp_dir().join(format!("nimqo-search-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([4; 32]), Fault::None).unwrap();
        let chat = "62811@s.whatsapp.net";
        inbox.enqueue(chat, "a", 1, "Meeting at 10").unwrap();
        inbox.enqueue(chat, "b", 2, "100% sure").unwrap();
        let ids = |q: &str| -> Vec<String> {
            inbox
                .search(q, 10)
                .unwrap()
                .into_iter()
                .map(|h| h.body.unwrap())
                .collect()
        };
        assert_eq!(ids("meeting"), ["Meeting at 10"]);
        assert_eq!(ids("10"), ["100% sure", "Meeting at 10"]);
        assert_eq!(ids("0%"), ["100% sure"]);
        assert!(ids("%").len() == 1 && ids("  ").is_empty());
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
