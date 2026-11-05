//! Profile pictures of chats: preview size, fetched when a chat is on
//! screen, at most once a day per chat, one at a time, and stored encrypted
//! like other media. A lookup goes to the WhatsApp server only, never to the
//! contact.

use std::collections::HashSet;
use std::io::Write as _;
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

use anyhow::{Result, anyhow, ensure};
use diesel::prelude::*;
use diesel::sql_types::{BigInt, Nullable, Text};
use sha2::{Digest as _, Sha256};
use whatsapp_rust::{
    Client, Jid, ProfilePictureLookup, ProfilePictureRequest, ProfilePictureTarget,
    ProfilePictureType,
};

use crate::inbox::Inbox;
use crate::media;
use crate::vault::Key;

/// Previews are a few KB; anything this large is not one.
const MAX_BYTES: usize = 512 * 1024;
/// How long a checked picture is trusted before asking again.
const RECHECK_SECS: i64 = 24 * 60 * 60;
/// Spacing between lookups, so a long chat list is not a burst.
const SPACING: Duration = Duration::from_millis(300);

pub struct Avatars {
    inbox: Inbox,
    dir: PathBuf,
    key: Key,
    /// Chats waiting or being fetched; a chat is queued once.
    queued: Mutex<HashSet<String>>,
    /// One lookup at a time.
    fetching: tokio::sync::Mutex<()>,
}

impl Avatars {
    #[must_use]
    pub fn new(inbox: Inbox, dir: PathBuf, key: Key) -> Self {
        Self {
            inbox,
            dir,
            key,
            queued: Mutex::default(),
            fetching: tokio::sync::Mutex::default(),
        }
    }

    /// The stored picture of `chat`, decrypted; None when there is none.
    ///
    /// # Errors
    /// The file exists but cannot be read or fails authentication.
    pub fn get(&self, chat: &str) -> Result<Option<Vec<u8>>> {
        match std::fs::read(self.file(chat)) {
            Ok(sealed) => Ok(Some(media::decrypt(&self.key, &sealed)?.to_vec())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    /// Fetches `chat`'s picture unless it was checked recently. Returns
    /// whether the stored picture changed.
    ///
    /// # Errors
    /// The lookup, download, or store fails.
    pub async fn refresh(&self, client: &Client, chat: &str, now: i64) -> Result<bool> {
        {
            let mut queued = self
                .queued
                .lock()
                .map_err(|_| anyhow!("avatar queue poisoned"))?;
            if !queued.insert(chat.to_owned()) {
                return Ok(false);
            }
        }
        let result = self.refresh_queued(client, chat, now).await;
        if let Ok(mut queued) = self.queued.lock() {
            queued.remove(chat);
        }
        result
    }

    async fn refresh_queued(&self, client: &Client, chat: &str, now: i64) -> Result<bool> {
        let _turn = self.fetching.lock().await;
        let (picture_id, checked) = self.state(chat)?;
        if checked.is_some_and(|at| now - at < RECHECK_SECS) {
            return Ok(false);
        }
        let jid: Jid = chat.parse().map_err(|_| anyhow!("not a chat id"))?;
        let target = if chat.ends_with("@g.us") {
            ProfilePictureTarget::Group(&jid)
        } else {
            ProfilePictureTarget::Contact(&jid)
        };
        // Only reuse the id when the bytes are really here.
        let have = self.file(chat).exists();
        let request = ProfilePictureRequest::new(target, ProfilePictureType::Preview)
            .existing_id(picture_id.as_deref().filter(|_| have));
        let lookup = client.pictures().lookup(request).await;
        tokio::time::sleep(SPACING).await;
        let changed = match lookup? {
            ProfilePictureLookup::Found(picture) => {
                let bytes = download(client, &picture.url).await?;
                write_private(&self.file(chat), &media::encrypt(&self.key, &bytes)?)?;
                self.record(chat, Some(&picture.id), now)?;
                true
            }
            ProfilePictureLookup::NotFound | ProfilePictureLookup::NotAuthorized => {
                let had = std::fs::remove_file(self.file(chat)).is_ok();
                self.record(chat, None, now)?;
                had
            }
            // Unchanged, or a state this version does not know: keep what is here.
            _ => {
                self.record(chat, picture_id.as_deref(), now)?;
                false
            }
        };
        if changed {
            self.inbox.notify_changed(vec![chat.to_owned()]);
        }
        Ok(changed)
    }

    /// The picture changed elsewhere: the next refresh asks again.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn invalidate(&self, chat: &str) -> Result<()> {
        let mut conn = self.inbox.lock()?;
        diesel::sql_query("UPDATE avatars SET checked_at = NULL WHERE jid = ?")
            .bind::<Text, _>(chat)
            .execute(&mut *conn)?;
        Ok(())
    }

    fn state(&self, chat: &str) -> Result<(Option<String>, Option<i64>)> {
        #[derive(QueryableByName)]
        struct State {
            #[diesel(sql_type = Nullable<Text>)]
            picture_id: Option<String>,
            #[diesel(sql_type = Nullable<BigInt>)]
            checked_at: Option<i64>,
        }
        let mut conn = self.inbox.lock()?;
        let row: Option<State> =
            diesel::sql_query("SELECT picture_id, checked_at FROM avatars WHERE jid = ?")
                .bind::<Text, _>(chat)
                .get_result(&mut *conn)
                .optional()?;
        Ok(row.map_or((None, None), |s| (s.picture_id, s.checked_at)))
    }

    fn record(&self, chat: &str, picture_id: Option<&str>, now: i64) -> Result<()> {
        let mut conn = self.inbox.lock()?;
        diesel::sql_query(
            "INSERT OR REPLACE INTO avatars (jid, picture_id, checked_at) VALUES (?, ?, ?)",
        )
        .bind::<Text, _>(chat)
        .bind::<Nullable<Text>, _>(picture_id)
        .bind::<BigInt, _>(now)
        .execute(&mut *conn)?;
        Ok(())
    }

    /// Named by a hash so file names reveal no numbers.
    fn file(&self, chat: &str) -> PathBuf {
        let hash = Sha256::digest(chat.as_bytes());
        let name = hex(&hash[..16]);
        self.dir.join(format!("{name}.nqm"))
    }
}

/// Plain HTTPS download from WhatsApp's picture servers only.
async fn download(client: &Client, url: &str) -> Result<Vec<u8>> {
    ensure!(is_picture_url(url), "picture URL is not a WhatsApp server");
    let response = client
        .http_client()
        .execute(whatsapp_rust::http::HttpRequest::get(url))
        .await?;
    ensure!(
        response.status_code == 200,
        "picture download: HTTP {}",
        response.status_code
    );
    ensure!(
        !response.body.is_empty() && response.body.len() <= MAX_BYTES,
        "picture size out of range"
    );
    Ok(response.body)
}

fn is_picture_url(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let host = rest.split(['/', '?', '#']).next().unwrap_or_default();
    !host.contains(['@', ':']) && (host == "whatsapp.net" || host.ends_with(".whatsapp.net"))
}

/// Lowercase hex.
pub(crate) fn hex(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut s, b| {
        let _ = write!(s, "{b:02x}");
        s
    })
}

/// Owner-only file, replaced atomically.
pub(crate) fn write_private(path: &Path, contents: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let mut f = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(contents)?;
    drop(f);
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_whatsapp_picture_hosts_are_fetched() {
        assert!(is_picture_url("https://pps.whatsapp.net/v/t61/x.jpg?ccb=1"));
        assert!(!is_picture_url("http://pps.whatsapp.net/x.jpg"));
        assert!(!is_picture_url("https://evil.example/whatsapp.net"));
        assert!(!is_picture_url("https://pps.whatsapp.net.evil.example/x"));
        assert!(!is_picture_url("https://pps.whatsapp.net@evil.example/x"));
        assert!(!is_picture_url("https://notwhatsapp.net/x"));
    }

    #[test]
    fn stores_pictures_encrypted_and_tracks_checks() {
        let base = std::env::temp_dir().join(format!("nimqo-avatars-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([5; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let avatars = Avatars::new(inbox, base.clone(), Key::new([6; 32]));
        let chat = "62811@s.whatsapp.net";
        assert_eq!(avatars.get(chat).unwrap(), None);
        write_private(
            &avatars.file(chat),
            &media::encrypt(&avatars.key, b"jpeg").unwrap(),
        )
        .unwrap();
        assert_eq!(avatars.get(chat).unwrap().as_deref(), Some(&b"jpeg"[..]));
        assert!(
            !std::fs::read(avatars.file(chat))
                .unwrap()
                .windows(4)
                .any(|w| w == b"jpeg")
        );
        avatars.record(chat, Some("id1"), 100).unwrap();
        assert_eq!(
            avatars.state(chat).unwrap(),
            (Some("id1".into()), Some(100))
        );
        avatars.invalidate(chat).unwrap();
        assert_eq!(avatars.state(chat).unwrap(), (Some("id1".into()), None));
        std::fs::remove_dir_all(&base).unwrap();
    }
}
