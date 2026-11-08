//! NIMQO protocol core: encrypted storage, key handling, and the
//! `whatsapp-rust` adapter. Phase 0 proof of concept (plan section 23).

pub mod attachments;
pub mod avatars;
pub mod channels;
pub mod contacts;
pub mod db;
mod effects;
pub mod flags;
pub mod forward;
pub mod groups;
pub mod history;
pub mod inbox;
pub mod lids;
pub mod media;
pub mod mutes;
pub mod outbox;
pub mod peer;
pub mod presence;
pub mod reads;
pub mod replies;
pub mod reupload;
pub mod search;
pub mod stickers;
pub mod stores;
pub mod timers;
pub mod vault;
