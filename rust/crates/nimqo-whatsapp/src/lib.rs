//! NIMQO protocol core: encrypted storage, key handling, and the
//! `whatsapp-rust` adapter. Phase 0 proof of concept (plan section 23).

pub mod db;
pub mod history;
pub mod inbox;
pub mod media;
pub mod outbox;
pub mod peer;
pub mod stores;
pub mod vault;
