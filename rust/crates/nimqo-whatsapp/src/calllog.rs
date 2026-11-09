//! Calls in chat timelines, as WhatsApp shows them ("Missed voice call",
//! "Video call · 3 min"). Stored as rows of kind "call" keyed by call id, so
//! the phone's record and this device's own one land on the same row. The
//! body is `<voice|video> <outcome> <seconds>`.

use anyhow::Result;
use wa::call_log_record::CallResult;
use whatsapp_rust::Jid;
use whatsapp_rust::prelude::wa;

use crate::inbox::{Inbox, ME, Row};

/// How a call ended, from the side of whoever owns the timeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Connected,
    /// Incoming and not answered.
    Missed,
    Declined,
    /// Outgoing and not answered.
    NoAnswer,
    Failed,
}

impl Outcome {
    fn name(self) -> &'static str {
        match self {
            Self::Connected => "connected",
            Self::Missed => "missed",
            Self::Declined => "declined",
            Self::NoAnswer => "noanswer",
            Self::Failed => "failed",
        }
    }

    /// The phone's record, or `None` for a call still ongoing or scheduled.
    #[must_use]
    pub fn of(result: Option<CallResult>, from_me: bool) -> Option<Self> {
        Some(match result.unwrap_or(CallResult::CONNECTED) {
            CallResult::CONNECTED | CallResult::ACCEPTEDELSEWHERE => Self::Connected,
            CallResult::REJECTED => Self::Declined,
            CallResult::CANCELLED | CallResult::MISSED | CallResult::UNAVAILABLE => {
                if from_me {
                    Self::NoAnswer
                } else {
                    Self::Missed
                }
            }
            CallResult::INVALID | CallResult::FAILED | CallResult::ABANDONED => Self::Failed,
            // Ongoing, upcoming, or newer than this build.
            _ => return None,
        })
    }
}

/// One finished call, filed under its chat (a person's phone-number chat or
/// a group).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub chat: String,
    /// Who placed it: [`ME`], or the caller's phone-number jid.
    pub sender: String,
    pub id: String,
    pub video: bool,
    pub outcome: Outcome,
    /// Unix seconds.
    pub started: i64,
    pub secs: i64,
}

impl Call {
    fn row(self) -> Row {
        let kind = if self.video { "video" } else { "voice" };
        Row {
            from_me: self.sender == ME,
            sender: self.sender,
            body: Some(format!(
                "{kind} {} {}",
                self.outcome.name(),
                self.secs.max(0)
            )),
            chat: self.chat,
            id: self.id,
            ts: self.started,
            kind: "call".into(),
            sender_name: String::new(),
            status: "",
            read: true,
            expires_at: None,
            media: None,
            quote: None,
            forwarded: false,
        }
    }
}

/// Keeps the first record of a call; later ones for the same id are ignored.
///
/// # Errors
/// The database write fails.
pub fn store(inbox: &Inbox, call: Call) -> Result<()> {
    let chat = call.chat.clone();
    inbox.commit(vec![call.row()], &[])?;
    inbox.notify(vec![chat]);
    Ok(())
}

/// The jid a phone record files the call under: the group, the person who
/// called, or for a call this account placed, the person called.
#[must_use]
pub fn peer_of(record: &wa::CallLogRecord, creator: Option<&Jid>, from_me: bool) -> Option<Jid> {
    if let Some(group) = record.group_jid.as_deref() {
        return group.parse().ok();
    }
    if !from_me {
        return creator.cloned();
    }
    record
        .participants
        .iter()
        .filter_map(|p| p.user_jid.as_deref()?.parse::<Jid>().ok())
        .find(|j| creator.is_none_or(|c| c.user != j.user))
}

/// A phone record's start in Unix seconds; some writers use milliseconds.
#[must_use]
pub fn started_of(record: &wa::CallLogRecord) -> Option<i64> {
    record
        .start_time
        .map(|t| if t > 100_000_000_000 { t / 1000 } else { t })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::inbox::Fault;
    use crate::vault::Key;

    #[test]
    fn outcomes_follow_the_direction() {
        let missed = Some(CallResult::MISSED);
        assert_eq!(Outcome::of(missed, false), Some(Outcome::Missed));
        assert_eq!(Outcome::of(missed, true), Some(Outcome::NoAnswer));
        assert_eq!(Outcome::of(Some(CallResult::ONGOING), true), None);
        assert_eq!(
            Outcome::of(Some(CallResult::ACCEPTEDELSEWHERE), false),
            Some(Outcome::Connected)
        );
    }

    #[test]
    fn a_placed_call_is_filed_under_the_person_called() {
        let me: Jid = "111@s.whatsapp.net".parse().unwrap();
        let mut record = wa::CallLogRecord::default();
        for jid in ["111@s.whatsapp.net", "222@s.whatsapp.net"] {
            let mut p = wa::call_log_record::ParticipantInfo::default();
            p.user_jid = Some(jid.into());
            record.participants.push(p);
        }
        let peer = peer_of(&record, Some(&me), true).unwrap();
        assert_eq!(peer.user, "222");
        assert_eq!(peer_of(&record, Some(&me), false), Some(me));
        record.group_jid = Some("333@g.us".into());
        assert_eq!(peer_of(&record, None, true).unwrap().user, "333");
        record.start_time = Some(1_700_000_000_123);
        assert_eq!(started_of(&record), Some(1_700_000_000));
    }

    #[test]
    fn the_first_record_of_a_call_is_kept() {
        let path = std::env::temp_dir().join(format!("nimqo-calls-{}.db", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let inbox = Inbox::open(&path, &Key::new([9; 32]), Fault::None).unwrap();
        let chat = "222@s.whatsapp.net";
        let call = Call {
            chat: chat.into(),
            sender: chat.into(),
            id: "c1".into(),
            video: true,
            outcome: Outcome::Connected,
            started: 50,
            secs: 125,
        };
        store(&inbox, call.clone()).unwrap();
        store(
            &inbox,
            Call {
                outcome: Outcome::Missed,
                ..call
            },
        )
        .unwrap();
        let rows = inbox.messages(chat, 10).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].kind, "call");
        assert_eq!(rows[0].body.as_deref(), Some("video connected 125"));
        drop(inbox);
        std::fs::remove_file(&path).unwrap();
    }
}
