//! Favorite stickers, starred on any of the account's devices (synced
//! as `favoriteSticker`). Kept as messages of `FAVORITES`, a chat that is
//! never listed, searched, or sent to: the picker shows and sends them
//! like the stickers seen in chats.

use anyhow::Result;
use base64::Engine as _;
use diesel::RunQueryDsl;
use diesel::sql_types::{BigInt, Text};
use whatsapp_rust::buffa::Message as _;
use whatsapp_rust::prelude::wa;

use crate::inbox::{Inbox, ME, Row};

pub const FAVORITES: &str = "favorites@stickers.nimqo";

/// The sticker message a favorite stands for: what is needed to download
/// it and send it again. None without a hash or an upload.
#[must_use]
pub fn sticker_of(filehash: &str, a: &wa::sync_action_value::StickerAction) -> Option<Vec<u8>> {
    let sha = base64::engine::general_purpose::STANDARD
        .decode(filehash)
        .ok()?;
    if sha.is_empty() || a.direct_path.as_deref().is_none_or(str::is_empty) || a.media_key.is_none()
    {
        return None;
    }
    let mut s = wa::message::StickerMessage::default();
    s.url.clone_from(&a.url);
    s.direct_path.clone_from(&a.direct_path);
    s.media_key.clone_from(&a.media_key);
    s.file_enc_sha256.clone_from(&a.file_enc_sha256);
    s.file_sha256 = Some(sha);
    s.mimetype.clone_from(&a.mimetype);
    s.width = a.width;
    s.height = a.height;
    s.file_length = a.file_length;
    s.is_lottie = a.is_lottie;
    s.is_avatar = a.is_avatar_sticker;
    Some(s.encode_to_vec())
}

impl Inbox {
    /// Keeps `sticker` (`sticker_of`) as a favorite, or drops the favorite
    /// with `filehash` when None.
    ///
    /// # Errors
    /// The store cannot be written.
    pub fn set_favorite_sticker(
        &self,
        filehash: &str,
        sticker: Option<Vec<u8>>,
        ts: i64,
    ) -> Result<()> {
        let Some(media) = sticker else {
            let mut conn = self.lock()?;
            diesel::sql_query("DELETE FROM messages WHERE chat = ? AND id = ?")
                .bind::<Text, _>(FAVORITES)
                .bind::<Text, _>(filehash)
                .execute(&mut *conn)?;
            return Ok(());
        };
        self.commit(
            vec![Row {
                chat: FAVORITES.to_owned(),
                sender: ME.to_owned(),
                id: filehash.to_owned(),
                ts,
                body: None,
                from_me: true,
                kind: "sticker".to_owned(),
                sender_name: String::new(),
                status: "sent",
                read: true,
                expires_at: None,
                media: Some(media),
                quote: None,
                forwarded: false,
            }],
            &[],
        )
    }

    /// Favorite stickers, the latest first, as (chat, seq).
    ///
    /// # Errors
    /// The query fails.
    pub fn favorite_stickers(&self) -> Result<Vec<(String, i64)>> {
        #[derive(diesel::QueryableByName)]
        struct Fav {
            #[diesel(sql_type = BigInt)]
            seq: i64,
        }
        let mut conn = self.lock()?;
        let rows: Vec<Fav> = diesel::sql_query(
            "SELECT rowid AS seq FROM messages WHERE chat = ? ORDER BY ts DESC, rowid DESC LIMIT 500",
        )
        .bind::<Text, _>(FAVORITES)
        .load(&mut *conn)?;
        Ok(rows
            .into_iter()
            .map(|r| (FAVORITES.to_owned(), r.seq))
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vault::Key;

    #[test]
    fn favorites_come_and_go_and_stay_out_of_the_chat_list() {
        let base = std::env::temp_dir().join(format!("nimqo-favs-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let inbox = Inbox::open(
            &base.join("app.db"),
            &Key::new([7; 32]),
            crate::inbox::Fault::None,
        )
        .unwrap();
        let mut a = wa::sync_action_value::StickerAction::default();
        assert_eq!(sticker_of("AAAA", &a), None, "no upload");
        a.direct_path = Some("/v/s".into());
        a.media_key = Some(vec![1; 32]);
        let media = sticker_of("AAAA", &a).unwrap();
        inbox.set_favorite_sticker("AAAA", Some(media), 10).unwrap();
        assert_eq!(inbox.favorite_stickers().unwrap().len(), 1);
        assert!(inbox.chats(10).unwrap().is_empty(), "never a chat");
        inbox.set_favorite_sticker("AAAA", None, 11).unwrap();
        assert_eq!(inbox.favorite_stickers().unwrap().len(), 0);
    }
}
