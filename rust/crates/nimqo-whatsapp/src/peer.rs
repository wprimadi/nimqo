//! Test-peer allowlist.
//!
//! The proof of concept runs on a real account, so it may only exchange
//! messages with one explicitly configured number. The number is supplied at
//! runtime and never committed.

use anyhow::{Result, bail};
use whatsapp_rust::Jid;
use whatsapp_rust::wacore::types::message::MessageSource;

pub struct Peer {
    digits: String,
}

impl Peer {
    /// Parses an international number such as `+62 822-xxxx`.
    ///
    /// # Errors
    /// The number is not 8 to 15 digits after removing `+`, spaces, and dashes.
    pub fn parse(number: &str) -> Result<Self> {
        let digits: String = number
            .chars()
            .filter(|c| !matches!(c, '+' | ' ' | '-'))
            .collect();
        if !(8..=15).contains(&digits.len()) || !digits.bytes().all(|b| b.is_ascii_digit()) {
            bail!("test peer must be an international phone number");
        }
        Ok(Self { digits })
    }

    #[must_use]
    pub fn jid(&self) -> Jid {
        Jid::pn(self.digits.as_str())
    }

    /// True for a one-to-one chat with the peer, whether addressed by phone
    /// number or LID (then the phone number arrives as an alternate address).
    #[must_use]
    pub fn matches(&self, source: &MessageSource) -> bool {
        if source.is_group {
            return false;
        }
        [
            Some(&source.chat),
            Some(&source.sender),
            source.sender_alt.as_ref(),
            source.recipient_alt.as_ref(),
        ]
        .into_iter()
        .flatten()
        .any(|j| j.is_pn() && j.user == self.digits)
    }
}

#[cfg(test)]
mod tests {
    use super::Peer;

    #[test]
    fn parses_and_rejects() {
        assert_eq!(
            Peer::parse("+62 812-3456-7890").unwrap().jid().user,
            "6281234567890"
        );
        assert!(Peer::parse("abc").is_err());
        assert!(Peer::parse("+1234").is_err());
        assert!(Peer::parse("+62 812 3456 7890 1234").is_err());
    }
}
