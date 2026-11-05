//! Message pictures: the thumbnail that comes inside the message is shown
//! at once; the full image is downloaded when its message is on screen and
//! stored encrypted like other media.

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::Mutex;

use anyhow::{Result, anyhow};
use diesel::prelude::*;
use diesel::sql_types::{BigInt, Binary, Text};
use sha2::{Digest as _, Sha256};
use whatsapp_rust::Client;
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::download::DownloadLimits;
use whatsapp_rust::prelude::wa;

use crate::inbox::Inbox;
use crate::media;
use crate::vault::Key;

/// Larger images are left as thumbnails.
const MAX_BYTES: u64 = 16 * 1024 * 1024;

pub struct Attachments {
    inbox: Inbox,
    dir: PathBuf,
    key: Key,
    queued: Mutex<HashSet<i64>>,
    /// Two downloads at a time.
    slots: tokio::sync::Semaphore,
}

/// A picture to show: the full image once downloaded, else the thumbnail.
pub struct Picture {
    pub bytes: Vec<u8>,
    pub full: bool,
}

#[derive(QueryableByName)]
struct Stored {
    #[diesel(sql_type = Text)]
    chat: String,
    #[diesel(sql_type = Text)]
    sender: String,
    #[diesel(sql_type = Text)]
    id: String,
    #[diesel(sql_type = Binary)]
    media: Vec<u8>,
}

impl Attachments {
    #[must_use]
    pub fn new(inbox: Inbox, dir: PathBuf, key: Key) -> Self {
        Self {
            inbox,
            dir,
            key,
            queued: Mutex::default(),
            slots: tokio::sync::Semaphore::new(2),
        }
    }

    /// The picture of message `seq` in `chat`, if it has one.
    ///
    /// # Errors
    /// The store or the file cannot be read, or fails authentication.
    pub fn picture(&self, chat: &str, seq: i64) -> Result<Option<Picture>> {
        let Some(stored) = self.stored(chat, seq)? else {
            return Ok(None);
        };
        match std::fs::read(self.file(&stored)) {
            Ok(sealed) => {
                let bytes = media::decrypt(&self.key, &sealed)?.to_vec();
                return Ok(Some(Picture { bytes, full: true }));
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let image = wa::message::ImageMessage::decode_from_slice(&stored.media)?;
        Ok(image
            .jpeg_thumbnail
            .filter(|t| !t.is_empty())
            .map(|bytes| Picture { bytes, full: false }))
    }

    /// Downloads the full image unless it is stored or being fetched.
    /// Returns whether a new image was stored.
    ///
    /// # Errors
    /// The store, download, or file write fails. Old messages' media may
    /// no longer be on WhatsApp's servers.
    pub async fn download(&self, client: &Client, chat: &str, seq: i64) -> Result<bool> {
        {
            let mut queued = self
                .queued
                .lock()
                .map_err(|_| anyhow!("download queue poisoned"))?;
            if !queued.insert(seq) {
                return Ok(false);
            }
        }
        let result = self.download_queued(client, chat, seq).await;
        if let Ok(mut queued) = self.queued.lock() {
            queued.remove(&seq);
        }
        result
    }

    async fn download_queued(&self, client: &Client, chat: &str, seq: i64) -> Result<bool> {
        let _slot = self.slots.acquire().await?;
        let Some(stored) = self.stored(chat, seq)? else {
            return Ok(false);
        };
        let file = self.file(&stored);
        if file.exists() {
            return Ok(false);
        }
        let image = wa::message::ImageMessage::decode_from_slice(&stored.media)?;
        let bytes = zeroize::Zeroizing::new(
            client
                .download(&image, DownloadLimits::new(MAX_BYTES + 1024, MAX_BYTES))
                .await?,
        );
        crate::avatars::write_private(&file, &media::encrypt(&self.key, &bytes)?)?;
        self.inbox.notify_changed(vec![stored.chat]);
        Ok(true)
    }

    /// Deletes stored images whose message is gone (expired, deleted by
    /// its sender, or removed). Returns how many were deleted.
    ///
    /// # Errors
    /// The store or the media folder cannot be read.
    pub fn sweep(&self) -> Result<usize> {
        #[derive(QueryableByName)]
        struct MessageKey {
            #[diesel(sql_type = Text)]
            chat: String,
            #[diesel(sql_type = Text)]
            sender: String,
            #[diesel(sql_type = Text)]
            id: String,
        }
        let keep: HashSet<std::ffi::OsString> = {
            let mut conn = self.inbox.lock()?;
            let rows: Vec<MessageKey> =
                diesel::sql_query("SELECT chat, sender, id FROM messages WHERE media IS NOT NULL")
                    .load(&mut *conn)?;
            rows.iter()
                .map(|k| file_name(&k.chat, &k.sender, &k.id).into())
                .collect()
        };
        let mut removed = 0;
        for entry in std::fs::read_dir(&self.dir)? {
            let entry = entry?;
            let name = entry.file_name();
            let ours = std::path::Path::new(&name)
                .extension()
                .is_some_and(|e| e == "nqm");
            if ours && !keep.contains(&name) && std::fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
        Ok(removed)
    }

    fn stored(&self, chat: &str, seq: i64) -> Result<Option<Stored>> {
        let mut conn = self.inbox.lock()?;
        Ok(diesel::sql_query(
            "SELECT chat, sender, id, media FROM messages
             WHERE rowid = ? AND chat = ? AND media IS NOT NULL AND kind <> 'deleted'",
        )
        .bind::<BigInt, _>(seq)
        .bind::<Text, _>(chat)
        .get_result(&mut *conn)
        .optional()?)
    }

    /// Named by a hash of the message key, so names reveal nothing.
    fn file(&self, stored: &Stored) -> PathBuf {
        self.dir
            .join(file_name(&stored.chat, &stored.sender, &stored.id))
    }
}

fn file_name(chat: &str, sender: &str, id: &str) -> String {
    let hash = Sha256::digest(format!("{chat}\n{sender}\n{id}"));
    format!("{}.nqm", crate::avatars::hex(&hash[..16]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn thumbnail_until_downloaded_then_the_stored_image() {
        let base = std::env::temp_dir().join(format!("nimqo-attach-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([7; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let chat = "62811@s.whatsapp.net";
        let mut image = wa::message::ImageMessage::default();
        image.jpeg_thumbnail = Some(b"thumb".to_vec());
        inbox.insert_media_for_test(chat, "m1", image.encode_to_vec());
        let seq = inbox.messages(chat, 10).unwrap()[0].seq;
        let store = Attachments::new(inbox, base.clone(), Key::new([8; 32]));

        let p = store.picture(chat, seq).unwrap().unwrap();
        assert_eq!((p.bytes.as_slice(), p.full), (&b"thumb"[..], false));
        assert!(
            store
                .picture("other@s.whatsapp.net", seq)
                .unwrap()
                .is_none(),
            "seq is per chat"
        );

        let stored = store.stored(chat, seq).unwrap().unwrap();
        let sealed = media::encrypt(&store.key, b"full").unwrap();
        crate::avatars::write_private(&store.file(&stored), &sealed).unwrap();
        let p = store.picture(chat, seq).unwrap().unwrap();
        assert_eq!((p.bytes.as_slice(), p.full), (&b"full"[..], true));
        // Deleted by its sender: nothing shown, and the file goes on sweep.
        store
            .inbox
            .apply_for_test(&[crate::effects::Effect::Revoke {
                chat: chat.into(),
                sender: chat.into(),
                target: "m1".into(),
            }]);
        assert!(store.picture(chat, seq).unwrap().is_none());
        assert_eq!(store.sweep().unwrap(), 1);
        assert!(!store.file(&stored).exists());
        std::fs::remove_dir_all(&base).unwrap();
    }
}
