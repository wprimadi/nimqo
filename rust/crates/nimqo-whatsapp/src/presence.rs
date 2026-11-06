//! What is known about a contact right now: online, last seen, typing, and
//! their "about" text. Memory only; none of it is stored.

use std::collections::HashMap;
use std::sync::Mutex;

/// Typing stops showing this long after the last "typing" signal, in case
/// the "paused" one never comes.
const TYPING_SECS: i64 = 15;

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Status {
    pub online: bool,
    pub last_seen_secs: Option<i64>,
    pub typing: bool,
    /// None until fetched, or when hidden by their privacy settings.
    pub about: Option<String>,
}

#[derive(Default)]
struct Entry {
    online: bool,
    last_seen_secs: Option<i64>,
    typing_since: Option<i64>,
    about: Option<String>,
    about_fetched: bool,
}

#[derive(Default)]
pub struct Presences {
    chats: Mutex<HashMap<String, Entry>>,
}

impl Presences {
    fn with<T>(&self, chat: &str, f: impl FnOnce(&mut Entry) -> T) -> T {
        let mut chats = self
            .chats
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        f(chats.entry(chat.to_owned()).or_default())
    }

    pub fn set_online(&self, chat: &str, online: bool, last_seen_secs: Option<i64>) {
        self.with(chat, |e| {
            e.online = online;
            if last_seen_secs.is_some() {
                e.last_seen_secs = last_seen_secs;
            }
            // Going offline ends typing.
            if !online {
                e.typing_since = None;
            }
        });
    }

    pub fn set_typing(&self, chat: &str, typing: bool, now: i64) {
        self.with(chat, |e| e.typing_since = typing.then_some(now));
    }

    /// Whether the about text still needs fetching; marks it as fetched, so
    /// it is asked for once per run.
    pub fn claim_about(&self, chat: &str) -> bool {
        self.with(chat, |e| !std::mem::replace(&mut e.about_fetched, true))
    }

    pub fn set_about(&self, chat: &str, about: Option<String>) {
        self.with(chat, |e| e.about = about.filter(|a| !a.trim().is_empty()));
    }

    #[must_use]
    pub fn status(&self, chat: &str, now: i64) -> Status {
        self.with(chat, |e| Status {
            online: e.online,
            last_seen_secs: e.last_seen_secs,
            typing: e.typing_since.is_some_and(|t| now - t < TYPING_SECS),
            about: e.about.clone(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn presence_typing_and_about() {
        let p = Presences::default();
        assert_eq!(p.status("a", 0), Status::default());
        p.set_online("a", true, None);
        p.set_typing("a", true, 100);
        assert!(p.status("a", 110).typing);
        assert!(!p.status("a", 100 + TYPING_SECS).typing, "typing expires");
        p.set_typing("a", true, 200);
        p.set_online("a", false, Some(205));
        let s = p.status("a", 206);
        assert!(!s.online && !s.typing);
        assert_eq!(s.last_seen_secs, Some(205));
        assert!(p.claim_about("a"));
        assert!(!p.claim_about("a"), "asked once");
        p.set_about("a", Some("  ".into()));
        assert_eq!(p.status("a", 0).about, None);
        p.set_about("a", Some("Busy".into()));
        assert_eq!(p.status("a", 0).about.as_deref(), Some("Busy"));
    }
}
