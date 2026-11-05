//! NIMQO protocol core: encrypted storage, key handling, and the
//! `whatsapp-rust` adapter. Phase 0 proof of concept (plan section 23).

pub mod attachments;
pub mod avatars;
pub mod contacts;
pub mod db;
mod effects;
pub mod history;
pub mod inbox;
pub mod lids;
pub mod media;
pub mod outbox;
pub mod peer;
pub mod reads;
pub mod replies;
pub mod search;
pub mod stores;
pub mod timers;
pub mod vault;
