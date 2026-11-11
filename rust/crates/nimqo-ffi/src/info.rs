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

    /// Group members with no receipt for own message `seq` yet, from the
    /// server's member list (so needs a connection). Empty when no receipt
    /// came at all: then the message predates receipts being kept, and
    /// everyone would look waiting.
    pub async fn waiting_members(&self, chat_id: String, seq: i64) -> Vec<Recipient> {
        let Ok(have) = self.inbox.recipients(&chat_id, seq) else {
            return Vec::new();
        };
        if have.is_empty() || !chat_id.ends_with("@g.us") {
            return Vec::new();
        }
        let Some(info) = self.group_info(chat_id).await else {
            return Vec::new();
        };
        // A receipt may name the member by number or by LID.
        let known: std::collections::HashSet<String> = have
            .iter()
            .flat_map(|r| {
                self.inbox
                    .aliases(&r.who)
                    .unwrap_or_else(|_| vec![r.who.clone()])
            })
            .collect();
        info.members
            .into_iter()
            .filter(|m| !m.is_me && !known.contains(&m.id))
            .map(|m| Recipient {
                name: m.saved_name.or(m.push_name),
                who: m.id,
                delivered_secs: None,
                read_secs: None,
                played_secs: None,
            })
            .collect()
    }
}
