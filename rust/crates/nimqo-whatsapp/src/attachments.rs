//! Message media: the thumbnail that comes inside the message is shown at
//! once; the full photo, video, or audio is downloaded when its message is
//! on screen and stored encrypted like other media.

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

/// Larger files are not downloaded: photos and audio stay at 16 MB (their
/// WhatsApp limit), videos at 64 MB, documents at 100 MB; all are held in
/// memory. ponytail: stream documents to disk if bigger ones matter.
fn max_bytes(kind: &str) -> u64 {
    let megabytes = match kind {
        "video" => 64,
        "document" => 100,
        _ => 16,
    };
    megabytes * 1024 * 1024
}

/// How long a download may take before it counts as failed (offline, it
/// would otherwise wait forever): 20 s plus 2 s per MB, about 4 Mbit/s.
/// ponytail: a fixed rate; time out on stalled progress instead if slow
/// links matter.
fn time_limit(bytes: u64) -> std::time::Duration {
    std::time::Duration::from_secs(20 + bytes / (512 * 1024))
}

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
    #[diesel(sql_type = Text)]
    kind: String,
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

    /// The picture of message `seq` in `chat`, if it has one: a photo, or
    /// the still of a video (complete as it is, so `full`).
    ///
    /// # Errors
    /// The store or the file cannot be read, or fails authentication.
    pub fn picture(&self, chat: &str, seq: i64) -> Result<Option<Picture>> {
        let Some(stored) = self.stored(chat, seq)? else {
            return Ok(None);
        };
        // Images and stickers show the downloaded file once it is here.
        if matches!(stored.kind.as_str(), "image" | "sticker")
            && let Some(bytes) = self.read(&stored)?
        {
            return Ok(Some(Picture {
                bytes: bytes.to_vec(),
                full: true,
            }));
        }
        let thumbnail = match stored.kind.as_str() {
            "image" => wa::message::ImageMessage::decode_from_slice(&stored.media)?.jpeg_thumbnail,
            "sticker" => {
                wa::message::StickerMessage::decode_from_slice(&stored.media)?.png_thumbnail
            }
            "video" => wa::message::VideoMessage::decode_from_slice(&stored.media)?.jpeg_thumbnail,
            _ => None,
        };
        Ok(thumbnail.filter(|t| !t.is_empty()).map(|bytes| Picture {
            bytes,
            // A video's still is all it shows; the rest still download.
            full: stored.kind == "video",
        }))
    }

    /// The downloaded file of message `seq` (photo, video, audio, or
    /// document), or
    /// `None` until it is downloaded.
    ///
    /// # Errors
    /// The store or the file cannot be read, or fails authentication.
    pub fn file_of(&self, chat: &str, seq: i64) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        match self.stored(chat, seq)? {
            Some(stored) => self.read(&stored),
            None => Ok(None),
        }
    }

    fn read(&self, stored: &Stored) -> Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
        match std::fs::read(self.file(stored)) {
            Ok(sealed) => Ok(Some(media::decrypt(&self.key, &sealed)?)),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Downloads the full file unless it is stored or being fetched.
    /// Returns whether a new file was stored.
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
        let item: Box<dyn whatsapp_rust::download::Downloadable> = match stored.kind.as_str() {
            "image" => Box::new(wa::message::ImageMessage::decode_from_slice(&stored.media)?),
            "video" => Box::new(wa::message::VideoMessage::decode_from_slice(&stored.media)?),
            "document" => Box::new(wa::message::DocumentMessage::decode_from_slice(
                &stored.media,
            )?),
            "sticker" => Box::new(wa::message::StickerMessage::decode_from_slice(
                &stored.media,
            )?),
            _ => Box::new(wa::message::AudioMessage::decode_from_slice(&stored.media)?),
        };
        let max = max_bytes(&stored.kind);
        let limit = time_limit(item.file_length().unwrap_or(max));
        let bytes = zeroize::Zeroizing::new(
            tokio::time::timeout(
                limit,
                client.download(item.as_ref(), DownloadLimits::new(max + 1024, max)),
            )
            .await
            .map_err(|_| anyhow!("download timed out"))??,
        );
        crate::avatars::write_private(&file, &media::encrypt(&self.key, &bytes)?)?;
        self.inbox.notify_changed(vec![stored.chat]);
        Ok(true)
    }

    /// Keeps a file being sent, encrypted, under the name a download of the
    /// same message would get; a sent photo then shows at full size.
    ///
    /// # Errors
    /// The file cannot be written.
    pub fn store_outgoing(&self, chat: &str, id: &str, bytes: &[u8]) -> Result<()> {
        let file = self.dir.join(file_name(chat, crate::inbox::ME, id));
        crate::avatars::write_private(&file, &media::encrypt(&self.key, bytes)?)
    }

    /// The file of an own pending message.
    ///
    /// # Errors
    /// The file is missing, unreadable, or fails authentication.
    pub fn outgoing(&self, chat: &str, id: &str) -> Result<zeroize::Zeroizing<Vec<u8>>> {
        let sealed = std::fs::read(self.dir.join(file_name(chat, crate::inbox::ME, id)))?;
        media::decrypt(&self.key, &sealed)
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
            "SELECT chat, sender, id, kind, media FROM messages
             WHERE rowid = ? AND chat = ? AND media IS NOT NULL
               AND kind IN ('image', 'video', 'audio', 'document', 'sticker')",
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
    fn downloads_get_more_time_when_larger() {
        assert_eq!(time_limit(0).as_secs(), 20);
        assert_eq!(time_limit(64 * 1024 * 1024).as_secs(), 148);
    }

    #[test]
    fn a_video_shows_its_still_and_audio_plays_once_downloaded() {
        let base = std::env::temp_dir().join(format!("nimqo-av-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let key = Key::new([7; 32]);
        let inbox = Inbox::open(&base.join("app.db"), &key, crate::inbox::Fault::None).unwrap();
        let chat = "62811@s.whatsapp.net";
        let mut video = wa::message::VideoMessage::default();
        video.jpeg_thumbnail = Some(b"still".to_vec());
        inbox.insert_kind_for_test(chat, "v", "video", video.encode_to_vec());
        let audio = wa::message::AudioMessage::default();
        inbox.insert_kind_for_test(chat, "a", "audio", audio.encode_to_vec());
        let doc = wa::message::DocumentMessage::default();
        inbox.insert_kind_for_test(chat, "d", "document", doc.encode_to_vec());
        let mut sticker = wa::message::StickerMessage::default();
        sticker.png_thumbnail = Some(b"tiny".to_vec());
        inbox.insert_kind_for_test(chat, "s", "sticker", sticker.encode_to_vec());
        let rows = inbox.messages(chat, 10).unwrap();
        let seq = |id: &str| rows.iter().find(|r| r.id == id).unwrap().seq;
        assert!(rows.iter().all(|r| r.has_media));
        let store = Attachments::new(inbox, base.clone(), Key::new([8; 32]));

        let p = store.picture(chat, seq("v")).unwrap().unwrap();
        assert_eq!((p.bytes.as_slice(), p.full), (&b"still"[..], true));
        assert!(store.picture(chat, seq("a")).unwrap().is_none());
        // A sticker: its small preview until the file is downloaded.
        let p = store.picture(chat, seq("s")).unwrap().unwrap();
        assert_eq!((p.bytes.as_slice(), p.full), (&b"tiny"[..], false));
        let stored = store.stored(chat, seq("s")).unwrap().unwrap();
        let sealed = media::encrypt(&store.key, b"webp").unwrap();
        crate::avatars::write_private(&store.file(&stored), &sealed).unwrap();
        let p = store.picture(chat, seq("s")).unwrap().unwrap();
        assert_eq!((p.bytes.as_slice(), p.full), (&b"webp"[..], true));
        assert!(store.picture(chat, seq("d")).unwrap().is_none());
        assert!(
            store.stored(chat, seq("d")).unwrap().is_some(),
            "documents download"
        );
        assert!(store.file_of(chat, seq("a")).unwrap().is_none());
        let stored = store.stored(chat, seq("a")).unwrap().unwrap();
        let sealed = media::encrypt(&store.key, b"ogg").unwrap();
        crate::avatars::write_private(&store.file(&stored), &sealed).unwrap();
        assert_eq!(
            store.file_of(chat, seq("a")).unwrap().unwrap().as_slice(),
            b"ogg"
        );
        std::fs::remove_dir_all(&base).unwrap();
    }

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
