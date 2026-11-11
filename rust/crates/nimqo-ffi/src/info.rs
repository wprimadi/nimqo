//! Message Info: who got, read, and played an own message, and when.

use crate::{Core, CoreError, err};

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct Recipient {
    /// Their chat id.
    pub who: String,
    /// Their name when known, else nil (show the number).
    pub name: Option<String>,
    pub delivered_secs: Option<i64>,
    pub read_secs: Option<i64>,
    pub played_secs: Option<i64>,
}

#[uniffi::export]
impl Core {
    /// The recipients of own message `seq` in `chat_id` whose receipts came,
    /// readers first. Receipts from before this was kept are not here.
    ///
    /// # Errors
    /// `Storage` if they cannot be read.
    pub fn message_info(&self, chat_id: &str, seq: i64) -> Result<Vec<Recipient>, CoreError> {
        let all = self
            .inbox
            .recipients(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?;
        Ok(all
            .into_iter()
            .map(|r| Recipient {
                name: r
                    .who
                    .split('@')
                    .next()
                    .and_then(|user| self.inbox.mention_name(user).ok().flatten()),
                who: r.who,
                delivered_secs: r.delivered,
                read_secs: r.read,
                played_secs: r.played,
            })
            .collect())
    }
}
