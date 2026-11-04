//! Master key handling (plan 11.3, ADR 0004).
//!
//! A 256-bit master key lives in the macOS Keychain. Each storage area gets
//! its own key derived with HKDF-SHA256, so no key is reused across databases
//! or media.

use anyhow::{Context, Result, bail};
use hkdf::Hkdf;
use security_framework::passwords::{
    PasswordOptions, generic_password, set_generic_password_options,
};
use security_framework::random::SecRandom;
use sha2::Sha256;
use zeroize::Zeroizing;

/// A 256-bit key that is wiped from memory when dropped.
pub type Key = Zeroizing<[u8; 32]>;

/// `errSecItemNotFound`.
const ITEM_NOT_FOUND: i32 = -25300;

/// Labels for derived keys. Changing a label makes existing data unreadable.
pub const PROTOCOL_DB: &str = "nimqo/v1/protocol-db";
pub const APP_DB: &str = "nimqo/v1/app-db";

pub struct MasterKey(Key);

impl MasterKey {
    /// Wraps existing key bytes. Used by tests; the app uses [`Self::load_or_create`].
    #[must_use]
    pub fn from_bytes(bytes: Key) -> Self {
        Self(bytes)
    }

    /// Loads the master key from the Keychain, creating it on first run.
    ///
    /// Any Keychain error other than "not found" fails closed: creating a new
    /// key there would silently orphan existing encrypted data.
    ///
    /// # Errors
    /// Keychain access fails, the stored item is malformed, or the system
    /// random generator fails.
    pub fn load_or_create(service: &str, account: &str) -> Result<Self> {
        let options = || {
            let mut o = PasswordOptions::new_generic_password(service, account);
            o.set_access_synchronized(Some(false));
            o
        };
        match generic_password(options()) {
            Ok(stored) => {
                let stored = Zeroizing::new(stored);
                let bytes: [u8; 32] = stored
                    .as_slice()
                    .try_into()
                    .context("Keychain master key has the wrong length")?;
                Ok(Self(Zeroizing::new(bytes)))
            }
            Err(e) if e.code() == ITEM_NOT_FOUND => {
                let mut bytes = Zeroizing::new([0u8; 32]);
                SecRandom::default()
                    .copy_bytes(bytes.as_mut_slice())
                    .map_err(|e| anyhow::anyhow!("system random generator failed: {e}"))?;
                set_generic_password_options(bytes.as_slice(), options())
                    .context("storing master key in the Keychain")?;
                Ok(Self(bytes))
            }
            Err(e) => bail!("Keychain unavailable, refusing to continue: {e}"),
        }
    }

    /// Derives an independent key for one storage area.
    ///
    /// # Panics
    /// Never: 32 bytes is always a valid HKDF-SHA256 output length.
    #[must_use]
    pub fn derive(&self, label: &str) -> Key {
        let mut out = Zeroizing::new([0u8; 32]);
        Hkdf::<Sha256>::new(None, self.0.as_slice())
            .expand(label.as_bytes(), out.as_mut_slice())
            .expect("32 bytes is a valid HKDF-SHA256 output length");
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derived_keys_are_distinct_and_stable() {
        let master = MasterKey::from_bytes(Zeroizing::new([7u8; 32]));
        let a = master.derive(PROTOCOL_DB);
        let b = master.derive(APP_DB);
        assert_ne!(*a, *b);
        assert_eq!(*a, *master.derive(PROTOCOL_DB));
        assert_ne!(*a, [7u8; 32]);
    }
}
