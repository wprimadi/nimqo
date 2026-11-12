//! UniFFI surface for the Swift app (plan section 8, ADR 0001).
//!
//! The app pairs, reports connection state, and reads and writes every chat.

use std::fs::File;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;

use nimqo_whatsapp::attachments::Attachments;
use nimqo_whatsapp::avatars::Avatars;
use nimqo_whatsapp::groups::Role;
use nimqo_whatsapp::inbox::{Fault, Inbox};
use nimqo_whatsapp::peer::Peer;
use nimqo_whatsapp::presence::Presences;
use nimqo_whatsapp::stores::{self, AlreadyRunning};
use nimqo_whatsapp::{history, lids};
pub use outbox::{GroupSetting, MemberChange};
use outbox::{OutgoingFile, StatusFont};
use whatsapp_rust::bot::BotHandle;
use whatsapp_rust::pair_code::{PairCodeOptions, PairCodeRejection};
use whatsapp_rust::prelude::*;
use whatsapp_rust::types::events::{Event, EventKind};
use whatsapp_rust::{ChatActivity, Client, PresenceStatus};

uniffi::setup_scaffolding!();

mod buttons;
mod calls;
mod cards;
mod channels;
mod chats;
mod communities;
mod info;
mod outbox;
mod privacy;
mod profile;
mod state;

pub use calls::{CallEnd, CallListener, PeerVideo};
pub use chats::{Chat, ChatMessage, Contact, Delivery, Mention, MessageKind, SearchHit};

/// A group as the server describes it, for the group's info card.
#[derive(Debug, uniffi::Record)]
pub struct GroupInfo {
    pub subject: Option<String>,
    pub description: Option<String>,
    pub created_secs: Option<i64>,
    /// Only admins can send.
    pub announce_only: bool,
    /// Only admins can edit the group's info.
    pub locked: bool,
    /// Owner, then admins, then members.
    pub members: Vec<GroupMember>,
    /// The account's own role; None when it is no longer a member.
    pub my_role: Option<MemberRole>,
}

#[derive(Debug, uniffi::Record)]
pub struct GroupMember {
    /// The member as the server addresses them, for admin actions.
    pub id: String,
    /// The account itself.
    pub is_me: bool,
    pub phone: Option<String>,
    /// From the user's address book.
    pub saved_name: Option<String>,
    /// Self-chosen; shown marked as such.
    pub push_name: Option<String>,
    pub role: MemberRole,
}

#[derive(Debug, PartialEq, Eq, uniffi::Enum)]
pub enum MemberRole {
    Owner,
    Admin,
    Member,
}

impl From<Role> for MemberRole {
    fn from(r: Role) -> Self {
        match r {
            Role::Owner => Self::Owner,
            Role::Admin => Self::Admin,
            Role::Member => Self::Member,
        }
    }
}

/// The person in a chat, as last heard: for the chat header.
#[derive(Debug, uniffi::Record)]
pub struct ContactStatus {
    pub online: bool,
    pub last_seen_secs: Option<i64>,
    pub typing: bool,
    /// The typing is recording a voice message.
    pub recording: bool,
    /// Their "about" text; nil until fetched or when hidden.
    pub about: Option<String>,
}

pub use state::ConnectionState;
use state::Input;

/// Implemented in Swift. Called from Rust worker threads.
#[uniffi::export(with_foreign)]
pub trait CoreListener: Send + Sync {
    fn on_state(&self, state: ConnectionState);
    /// Raw pairing payload; the app renders it as a QR code.
    fn on_qr(&self, code: String, timeout_secs: u64);
    /// Eight-character code to type on the phone, after `request_pair_code`.
    fn on_pair_code(&self, code: String, timeout_secs: u64);
    /// No code is coming. `throttled` means wait before asking again.
    fn on_pair_code_error(&self, throttled: bool, retry_after_secs: Option<u64>);
    /// New messages were stored in these chats; reload what is shown.
    fn on_chats_changed(&self, chat_ids: Vec<String>);
}

/// Grouped by what the user can do about it. `detail` is for logs and bug
/// reports; it never contains message content.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum CoreError {
    /// The number entered for pairing is not an international number.
    InvalidPhoneNumber,
    /// Another NIMQO process (app or CLI) has the session open.
    AlreadyRunning,
    /// The Keychain key or an encrypted database is unavailable. NIMQO fails
    /// closed here and never falls back to plaintext.
    Storage { detail: String },
    /// The client could not be built or started.
    Startup { detail: String },
    /// The message was not queued; `reason` is shown to the user.
    SendRefused { reason: String },
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let (kind, detail) = match self {
            Self::InvalidPhoneNumber => (
                "invalid phone number",
                "use the international format, e.g. +62 812 3456 7890",
            ),
            Self::AlreadyRunning => (
                "already running",
                "another NIMQO process has the session open",
            ),
            Self::Storage { detail } => ("encrypted storage unavailable", detail.as_str()),
            Self::Startup { detail } => ("cannot start", detail.as_str()),
            Self::SendRefused { reason } => ("not sent", reason.as_str()),
        };
        write!(f, "{kind}: {detail}")
    }
}

impl std::error::Error for CoreError {}

pub(crate) fn err<E: std::fmt::Display>(make: fn(String) -> CoreError) -> impl Fn(E) -> CoreError {
    move |e| make(format!("{e:#}"))
}

/// Current state plus the listener to tell about changes.
struct Machine {
    state: Mutex<ConnectionState>,
    listener: Arc<dyn CoreListener>,
}

impl Machine {
    fn feed(&self, input: Input) {
        let Ok(mut state) = self.state.lock() else {
            return;
        };
        let next = state.next(input);
        if next != *state {
            log::info!("connection {:?} -> {next:?}", *state);
            state.clone_from(&next);
            drop(state);
            self.listener.on_state(next);
        }
    }

    fn current(&self) -> ConnectionState {
        self.state.lock().map_or(
            ConnectionState::Failed {
                reason: "state lock poisoned".into(),
            },
            |s| s.clone(),
        )
    }
}

#[derive(uniffi::Object)]
pub struct Core {
    runtime: tokio::runtime::Runtime,
    handle: Mutex<Option<BotHandle>>,
    client: Arc<Client>,
    machine: Arc<Machine>,
    /// Number used for code pairing, kept to re-request when the server asks.
    pair_phone: Arc<Mutex<Option<String>>>,
    dir: PathBuf,
    inbox: Inbox,
    sender: Arc<outbox::Sender>,
    avatars: Arc<Avatars>,
    attachments: Arc<Attachments>,
    presences: Arc<Presences>,
    calls: Arc<calls::Calls>,
    /// Data-directory lock; released on drop or after a reset.
    lock: Mutex<Option<File>>,
}

/// How long WhatsApp lets an own message be edited, in seconds.
#[uniffi::export]
#[must_use]
pub fn edit_window_secs() -> i64 {
    outbox::EDIT_WINDOW_SECS
}

/// How long WhatsApp lets an own message be deleted for everyone.
#[uniffi::export]
#[must_use]
pub fn delete_window_secs() -> i64 {
    outbox::REVOKE_WINDOW_SECS
}

impl Core {
    /// Runs `f` on the client's runtime.
    async fn on_runtime<T: Send + 'static>(
        &self,
        f: impl Future<Output = Result<T, CoreError>> + Send + 'static,
    ) -> Result<T, CoreError> {
        self.runtime
            .spawn(f)
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }
}

#[uniffi::export]
impl Core {
    /// Opens the encrypted stores and connects. Blocks until the connection
    /// task is running, so call it off the main thread.
    ///
    /// # Errors
    /// Another process holds the session, or the stores or client cannot
    /// start.
    #[uniffi::constructor]
    pub fn start(listener: Arc<dyn CoreListener>) -> Result<Arc<Self>, CoreError> {
        init_logging();
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .map_err(|e| CoreError::Startup {
                detail: e.to_string(),
            })?;
        listener.on_state(ConnectionState::Connecting);
        let machine = Arc::new(Machine {
            state: Mutex::new(ConnectionState::Connecting),
            listener,
        });
        let pair_phone = Arc::new(Mutex::new(None));
        let session = runtime.block_on(connect(Arc::clone(&machine), Arc::clone(&pair_phone)))?;
        runtime.spawn(purge_expired(
            session.inbox.clone(),
            Arc::clone(&session.attachments),
        ));
        runtime.spawn(keep_reconnecting(
            Arc::clone(&machine),
            Arc::clone(&session.client),
        ));
        Ok(Arc::new(Self {
            runtime,
            handle: Mutex::new(Some(session.handle)),
            client: session.client,
            machine,
            pair_phone,
            dir: session.dir,
            inbox: session.inbox,
            sender: session.sender,
            avatars: session.avatars,
            attachments: session.attachments,
            presences: session.presences,
            calls: session.calls,
            lock: Mutex::new(Some(session.lock)),
        }))
    }

    /// Chats by most recent activity. Reads the local store only.
    ///
    /// # Errors
    /// The encrypted store cannot be read.
    pub fn chats(&self) -> Result<Vec<Chat>, CoreError> {
        const LIMIT: i64 = 500;
        let now = unix_now();
        let mut names = self.own_mention_names();
        let mut name = |user: &str| {
            names
                .entry(user.to_owned())
                .or_insert_with(|| self.inbox.mention_name(user).ok().flatten())
                .clone()
        };
        let mut chats: Vec<Chat> = self
            .inbox
            .chats(LIMIT)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(Chat::from)
            .collect();
        for chat in &mut chats {
            // "@628…" in the preview reads as the person's name.
            if let Some(body) = &chat.last_body {
                chat.last_body = Some(chats::named_mentions(body, &mut name));
            }
            let status = self.presences.status(&chat.id, now);
            if status.typing {
                chat.activity = Some(chats::Activity {
                    recording: status.recording,
                    who: status.typist.map(|user| name(&user).unwrap_or(user)),
                });
            }
        }
        Ok(chats)
    }

    /// A mention of this account carries its own number or LID, which no
    /// contact or push name lists.
    fn own_mention_names(&self) -> std::collections::HashMap<String, Option<String>> {
        [self.client.pn(), self.client.lid()]
            .into_iter()
            .flatten()
            .map(|me| (me.user.to_string(), Some("You".to_owned())))
            .collect()
    }

    /// The latest messages of one chat, oldest first.
    ///
    /// # Errors
    /// The encrypted store cannot be read.
    pub fn messages(&self, chat_id: &str, limit: u32) -> Result<Vec<ChatMessage>, CoreError> {
        self.older_messages(chat_id, None, limit)
    }

    /// Up to `limit` messages before the one at `(timestamp_secs, seq)`, or
    /// the latest when `None`; oldest first. Fewer than `limit` means the
    /// start of the chat.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn older_messages(
        &self,
        chat_id: &str,
        before: Option<Cursor>,
        limit: u32,
    ) -> Result<Vec<ChatMessage>, CoreError> {
        let mut messages: Vec<ChatMessage> = self
            .inbox
            .messages_before(
                chat_id,
                before.map(|c| (c.timestamp_secs, c.seq)),
                i64::from(limit),
            )
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(ChatMessage::from)
            .collect();
        let videos: Vec<i64> = messages
            .iter()
            .filter(|m| m.kind == MessageKind::Video)
            .map(|m| m.seq)
            .collect();
        if !videos.is_empty() {
            let gifs =
                nimqo_whatsapp::forward::gifs(&self.inbox, chat_id, &videos).unwrap_or_default();
            for m in &mut messages {
                m.gif = gifs.contains(&m.seq);
            }
        }
        // As on the phone, a status shows only when its poster is saved.
        if chat_id == nimqo_whatsapp::inbox::STATUS {
            messages.retain(|m| m.from_me || self.inbox.is_contact(&m.sender).unwrap_or(false));
        }
        let mut names = self.own_mention_names();
        let mut name = |user: &str| {
            names
                .entry(user.to_owned())
                .or_insert_with(|| self.inbox.mention_name(user).ok().flatten())
                .clone()
        };
        for m in &mut messages {
            // A quoted message's mentions read as names, as in the list.
            if let Some(quoted) = m.reply.as_mut().and_then(|r| r.body.as_mut()) {
                *quoted = chats::named_mentions(quoted, &mut name);
            }
            let Some(body) = &m.body else { continue };
            for user in chats::mentioned_users(body) {
                if let Some(name) = name(user) {
                    m.mentions.push(chats::Mention {
                        user: user.to_owned(),
                        name,
                    });
                }
            }
        }
        Ok(messages)
    }

    /// Messages containing `text` in any chat, newest first, at most 100.
    /// Runs on this Mac only.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn search_messages(&self, text: &str) -> Result<Vec<SearchHit>, CoreError> {
        Ok(self
            .inbox
            .search(text, 100)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(SearchHit::from)
            .collect())
    }

    /// Starred messages still stored here, newest first.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn starred_messages(&self) -> Result<Vec<SearchHit>, CoreError> {
        Ok(self
            .inbox
            .starred(500)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(SearchHit::from)
            .collect())
    }

    /// Whether the app may write, react, and mute in `chat_id`: a person
    /// or group already stored here.
    #[must_use]
    pub fn can_send(&self, chat_id: &str) -> bool {
        outbox::Sender::may_send(chat_id).is_ok()
    }

    /// The picture of message `seq`: the full image once downloaded, else
    /// the thumbnail that came with the message.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn picture(&self, chat_id: &str, seq: i64) -> Result<Option<MessagePicture>, CoreError> {
        Ok(self
            .attachments
            .picture(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .map(|p| MessagePicture {
                bytes: p.bytes,
                full: p.full,
            }))
    }

    /// Downloads message `seq`'s photo, video, audio, or document;
    /// `on_chats_changed` reports it stored. False when it failed (offline,
    /// or gone from WhatsApp's servers); it may be asked for again.
    pub async fn download_media(&self, chat_id: String, seq: i64) -> bool {
        let (store, client) = (Arc::clone(&self.attachments), Arc::clone(&self.client));
        // Asking for old media again reaches the sender's phone: only in a
        // person's or group's chat, not a channel.
        let reupload_chat = if outbox::Sender::may_send(&chat_id).is_ok() {
            chat_id.clone()
        } else {
            String::new()
        };
        let done = self
            .runtime
            .spawn(async move { store.download(&client, &chat_id, seq, &reupload_chat).await })
            .await;
        match done {
            Ok(Ok(_)) => true,
            Ok(Err(e)) => {
                log::info!("media not downloaded: {e:#}");
                false
            }
            Err(_) => false,
        }
    }

    /// Sends a message that failed again, from the start.
    ///
    /// # Errors
    /// `Storage` if it cannot be queued again.
    pub fn retry_message(&self, chat_id: &str, seq: i64) -> Result<(), CoreError> {
        let queued = self
            .inbox
            .retry_failed(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?;
        if queued {
            self.sender
                .listener
                .on_chats_changed(vec![chat_id.to_owned()]);
            let sender = Arc::clone(&self.sender);
            self.runtime.spawn(async move { sender.flush(false).await });
        }
        Ok(())
    }

    /// What an audio message's bubble shows before it is downloaded.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn audio_info(&self, chat_id: &str, seq: i64) -> Result<Option<AudioInfo>, CoreError> {
        Ok(self
            .attachments
            .audio(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .map(|(seconds, voice, waveform)| AudioInfo {
                seconds,
                voice,
                waveform,
            }))
    }

    /// Message `seq`'s downloaded video, audio, or document, in memory; nil
    /// until `download_media` has stored it.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn media_file(&self, chat_id: &str, seq: i64) -> Result<Option<Vec<u8>>, CoreError> {
        Ok(self
            .attachments
            .file_of(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .map(|bytes| bytes.to_vec()))
    }

    /// An animated sticker's Lottie JSON, unpacked in memory from its
    /// downloaded archive and checked; nil until downloaded, or if it is
    /// not one or fails the checks.
    ///
    /// # Errors
    /// `Storage` if it cannot be read.
    pub fn sticker_animation(&self, chat_id: &str, seq: i64) -> Result<Option<Vec<u8>>, CoreError> {
        self.attachments
            .sticker_animation(chat_id, seq)
            .map_err(err(|detail| CoreError::Storage { detail }))
    }

    /// Asks the server for the group's members, admins and description.
    /// Read-only and not stored; nil when offline or not a group.
    pub async fn group_info(&self, chat_id: String) -> Option<GroupInfo> {
        let (client, inbox) = (Arc::clone(&self.client), self.inbox.clone());
        let fetched = self
            .runtime
            .spawn(async move { nimqo_whatsapp::groups::info(&inbox, &client, &chat_id).await })
            .await;
        let info = match fetched {
            Ok(Ok(info)) => info,
            Ok(Err(e)) => {
                log::info!("group info not fetched: {e:#}");
                return None;
            }
            Err(e) => {
                log::warn!("group info task failed: {e}");
                return None;
            }
        };
        log::info!("group info: {} member(s)", info.members.len());
        Some(GroupInfo {
            subject: info.subject,
            description: info.description,
            created_secs: info.created_secs,
            announce_only: info.announce_only,
            locked: info.locked,
            my_role: info.my_role.map(MemberRole::from),
            members: info
                .members
                .into_iter()
                .map(|m| GroupMember {
                    id: m.id,
                    is_me: m.is_me,
                    phone: m.phone,
                    saved_name: m.saved_name,
                    push_name: m.push_name,
                    role: m.role.into(),
                })
                .collect(),
        })
    }

    /// What is known now about the person in `chat_id`, from memory.
    #[must_use]
    pub fn contact_status(&self, chat_id: &str) -> ContactStatus {
        let s = self.presences.status(chat_id, unix_now());
        ContactStatus {
            online: s.online,
            last_seen_secs: s.last_seen_secs,
            typing: s.typing,
            recording: s.recording,
            about: s.about,
        }
    }

    /// The chat is open: fetches the person's about text once per run and
    /// follows whether they are online or typing. Changes arrive through
    /// `on_chats_changed`.
    pub fn watch_contact(&self, chat_id: String) {
        let Ok(jid) = chat_id.parse::<Jid>() else {
            return;
        };
        if !chat_id.ends_with("@s.whatsapp.net") && !chat_id.ends_with("@lid") {
            return;
        }
        let (client, presences, inbox) = (
            Arc::clone(&self.client),
            Arc::clone(&self.presences),
            self.inbox.clone(),
        );
        self.runtime.spawn(async move {
            if presences.claim_about(&chat_id) {
                match client
                    .contacts()
                    .get_user_info(std::slice::from_ref(&jid))
                    .await
                {
                    Ok(info) => {
                        let about = info.into_values().next().and_then(|u| u.status);
                        log::info!(
                            "about fetched: {}",
                            if about.is_some() { "set" } else { "none" }
                        );
                        presences.set_about(&chat_id, about);
                        inbox.notify_changed(vec![chat_id.clone()]);
                    }
                    Err(e) => {
                        log::info!("about not fetched: {e}");
                        presences.unclaim_about(&chat_id);
                    }
                }
            }
            if let Err(e) = client.presence().subscribe(jid).await {
                log::info!("presence not followed: {e}");
            }
        });
    }

    /// The stored profile picture of a chat (JPEG), if any.
    ///
    /// # Errors
    /// `Storage` if the stored picture cannot be read.
    pub fn avatar(&self, chat_id: &str) -> Result<Option<Vec<u8>>, CoreError> {
        self.avatars
            .get(chat_id)
            .map_err(err(|detail| CoreError::Storage { detail }))
    }

    /// Fetches a chat's profile picture in the background unless it was
    /// checked in the last day; `on_chats_changed` reports a new one. Call it
    /// for chats on screen only.
    pub fn request_avatar(&self, chat_id: String) {
        let (avatars, client) = (Arc::clone(&self.avatars), Arc::clone(&self.client));
        self.runtime.spawn(async move {
            if let Err(e) = avatars.refresh(&client, &chat_id, unix_now()).await {
                log::info!("avatar not fetched: {e:#}");
            }
        });
    }

    /// Asks the linked phone (never a contact) for messages before the oldest
    /// one stored for `chat_id`; they arrive later as history. False when
    /// nothing is stored to anchor the request.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read or the chat id is malformed.
    pub fn request_older_history(&self, chat_id: &str) -> Result<bool, CoreError> {
        // WhatsApp Web asks for 50 at a time.
        const COUNT: i32 = 50;
        let Some((id, from_me, ts)) = self
            .inbox
            .oldest(chat_id)
            .map_err(err(|detail| CoreError::Storage { detail }))?
        else {
            return Ok(false);
        };
        let jid: Jid = chat_id.parse().map_err(|_| CoreError::Storage {
            detail: "not a chat id".into(),
        })?;
        let client = Arc::clone(&self.client);
        self.runtime.spawn(async move {
            // The phone answers later with a history chunk, imported like any
            // other; a phone that is offline simply never answers.
            match client
                .fetch_message_history(&jid, &id, from_me, ts * 1000, COUNT)
                .await
            {
                Ok(_) => log::info!("asked the phone for older history"),
                Err(e) => log::warn!("older history not requested: {e:#}"),
            }
        });
        Ok(true)
    }

    /// Marks the chat read here. Only the test chat also tells the sender
    /// (read receipts); every other chat stays read-only toward WhatsApp.
    ///
    /// # Errors
    /// `Storage` if the read state cannot be written.
    pub fn mark_chat_read(&self, chat_id: &str) -> Result<(), CoreError> {
        let read = self
            .inbox
            .mark_chat_read(chat_id)
            .map_err(|e| CoreError::Storage {
                detail: format!("{e:#}"),
            })?;
        if read.is_empty() {
            return Ok(());
        }
        self.sender
            .listener
            .on_chats_changed(vec![chat_id.to_owned()]);
        let sender = Arc::clone(&self.sender);
        let chat = chat_id.to_owned();
        let read: Vec<(String, String)> = read.into_iter().map(|u| (u.sender, u.id)).collect();
        self.runtime
            .spawn(async move { sender.send_read_receipts(&chat, read).await });
        Ok(())
    }

    /// Marks status update `seq` viewed here. With `tell_poster` a view
    /// receipt goes to the poster; without it nobody learns it was seen.
    ///
    /// # Errors
    /// `Storage` if the view cannot be recorded.
    pub fn view_status(&self, seq: i64, tell_poster: bool) -> Result<(), CoreError> {
        let viewed = self
            .inbox
            .view_status(seq)
            .map_err(err(|detail| CoreError::Storage { detail }))?;
        let Some(viewed) = viewed else { return Ok(()) };
        self.sender
            .listener
            .on_chats_changed(vec![nimqo_whatsapp::inbox::STATUS.to_owned()]);
        if !tell_poster {
            return Ok(());
        }
        if let Ok(poster) = viewed.sender.parse::<Jid>() {
            let sender = Arc::clone(&self.sender);
            self.runtime
                .spawn(async move { sender.send_status_receipt(poster, viewed.id).await });
        }
        Ok(())
    }

    /// Status updates (seqs) not viewed yet.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn unviewed_statuses(&self) -> Result<Vec<i64>, CoreError> {
        self.inbox
            .unviewed_statuses()
            .map_err(err(|detail| CoreError::Storage { detail }))
    }

    /// Reacts to message `seq` with `emoji`; an empty one removes it.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, more than one emoji, a
    /// message that is gone, or a failed send; `Storage` if it cannot be
    /// stored.
    pub async fn react(&self, chat_id: String, seq: i64, emoji: String) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.runtime
            .spawn(async move { sender.react(&chat_id, seq, &emoji).await })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }

    /// Posts a status update: `text` alone on `background` (RGB) in `font`,
    /// or a JPEG photo or an MP4 video of at most a minute with `text` as
    /// its caption, to the audience in the phone's status privacy.
    ///
    /// # Errors
    /// `SendRefused` for an empty or too long status, a photo that is not
    /// JPEG, a file too large, or a failed post; `Storage` if it cannot be
    /// kept.
    pub async fn post_status(
        &self,
        text: String,
        photo: Option<OutgoingFile>,
        background: u32,
        font: StatusFont,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.runtime
            .spawn(async move {
                sender
                    .post_status(&text, photo.as_ref(), background, font)
                    .await
            })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }

    /// Deletes own status update `seq` for everyone who can see it.
    ///
    /// # Errors
    /// `SendRefused` if it is not own or the revoke fails; `Storage` if it
    /// cannot be removed here.
    pub async fn delete_status(&self, seq: i64) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.runtime
            .spawn(async move { sender.delete_status(seq).await })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
    }

    /// Mutes or unmutes a chat on every device of the account.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, or when WhatsApp does
    /// not take the change; `Storage` if it cannot be stored.
    pub async fn set_muted(&self, chat_id: String, muted: bool) -> Result<(), CoreError> {
        let until = if muted {
            nimqo_whatsapp::mutes::FOREVER
        } else {
            0
        };
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_mute_until(&chat_id, until).await })
            .await
    }

    /// Mutes a chat for `seconds` from now, on every device of the account.
    ///
    /// # Errors
    /// As `set_muted`.
    pub async fn mute_for(&self, chat_id: String, seconds: u64) -> Result<(), CoreError> {
        let ms = i64::try_from(seconds.saturating_mul(1000)).unwrap_or(i64::MAX);
        let until = unix_now().saturating_mul(1000).saturating_add(ms);
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_mute_until(&chat_id, until).await })
            .await
    }

    /// Turns disappearing messages on for `seconds`, or off with 0, for
    /// everyone in the chat.
    ///
    /// # Errors
    /// `SendRefused` when WhatsApp does not take the change (in a group,
    /// when only admins may change it); `Storage` if it cannot be stored.
    pub async fn set_chat_timer(&self, chat_id: String, seconds: u32) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_timer(&chat_id, seconds).await })
            .await
    }

    /// Pins or unpins a chat on every device of the account.
    ///
    /// # Errors
    /// `SendRefused` when WhatsApp does not take the change; `Storage` if it
    /// cannot be stored.
    pub async fn set_pinned(&self, chat_id: String, pinned: bool) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_pinned(&chat_id, pinned).await })
            .await
    }

    /// Archives or unarchives a chat on every device of the account.
    ///
    /// # Errors
    /// As `set_pinned`.
    pub async fn set_archived(&self, chat_id: String, archived: bool) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_archived(&chat_id, archived).await })
            .await
    }

    /// Stars or unstars message `seq` on every device of the account.
    ///
    /// # Errors
    /// As `set_pinned`.
    pub async fn set_starred(
        &self,
        chat_id: String,
        seq: i64,
        starred: bool,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_starred(&chat_id, seq, starred).await })
            .await
    }

    /// Replaces the text of own message `seq` for everyone.
    ///
    /// # Errors
    /// `SendRefused` for someone else's message, a non-text one, one older
    /// than the edit window, or when WhatsApp does not take it.
    pub async fn edit_message(
        &self,
        chat_id: String,
        seq: i64,
        text: String,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.edit(&chat_id, seq, &text).await })
            .await
    }

    /// Deletes own message `seq` for everyone.
    ///
    /// # Errors
    /// `SendRefused` for someone else's message, one older than the delete
    /// window, or when WhatsApp does not take it.
    pub async fn delete_for_everyone(&self, chat_id: String, seq: i64) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.revoke(&chat_id, seq).await })
            .await
    }

    /// Deletes message `seq` from this account's devices only; others
    /// still have it.
    ///
    /// # Errors
    /// `SendRefused` when the other devices could not be told, or the
    /// message is gone; `Storage` if it cannot be deleted here.
    pub async fn delete_for_me(&self, chat_id: String, seq: i64) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.delete_for_me(&chat_id, seq).await })
            .await
    }

    /// Queues a forwarded copy of message `seq` in each of `to` (one to
    /// five chats) and starts sending, like `send_text`.
    ///
    /// # Errors
    /// `SendRefused` for a target that is not a person or group, too many
    /// targets, or a message that cannot be forwarded.
    pub fn forward(&self, chat_id: &str, seq: i64, to: Vec<String>) -> Result<(), CoreError> {
        self.sender.forward(chat_id, seq, to)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Renames a group.
    ///
    /// # Errors
    /// `SendRefused` for an empty or too long name, or when the server does
    /// not allow it (only admins, in a locked group).
    pub async fn set_group_subject(
        &self,
        chat_id: String,
        subject: String,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_group_subject(&chat_id, &subject).await })
            .await
    }

    /// Sets a group's description; an empty one removes it.
    ///
    /// # Errors
    /// As `set_group_subject`.
    pub async fn set_group_description(
        &self,
        chat_id: String,
        text: String,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_group_description(&chat_id, &text).await })
            .await
    }

    /// Turns a group setting on or off. Admins only.
    ///
    /// # Errors
    /// `SendRefused` when the server does not allow it.
    pub async fn set_group_setting(
        &self,
        chat_id: String,
        setting: GroupSetting,
        on: bool,
    ) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.set_group_setting(&chat_id, setting, on).await })
            .await
    }

    /// Adds, removes, promotes, or demotes members (person ids). Returns how
    /// many the server turned down.
    ///
    /// # Errors
    /// `SendRefused` for an id that is not a person, or when the server does
    /// not allow it at all.
    pub async fn change_group_members(
        &self,
        chat_id: String,
        members: Vec<String>,
        change: MemberChange,
    ) -> Result<u32, CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.change_members(&chat_id, &members, change).await })
            .await
    }

    /// The group's invite link; `reset` replaces it with a new one.
    ///
    /// # Errors
    /// `SendRefused` when the server does not allow it.
    pub async fn group_invite_link(
        &self,
        chat_id: String,
        reset: bool,
    ) -> Result<String, CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.group_invite_link(&chat_id, reset).await })
            .await
    }

    /// Leaves a group. Its messages stay here.
    ///
    /// # Errors
    /// `SendRefused` when the server does not take it.
    pub async fn leave_group(&self, chat_id: String) -> Result<(), CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.leave_group(&chat_id).await })
            .await
    }

    /// Creates a group and returns its chat id.
    ///
    /// # Errors
    /// `SendRefused` for no name, no members, or when the server refuses.
    pub async fn create_group(
        &self,
        subject: String,
        members: Vec<String>,
    ) -> Result<String, CoreError> {
        let sender = Arc::clone(&self.sender);
        self.on_runtime(async move { sender.create_group(&subject, &members).await })
            .await
    }

    /// Queues a photo or document and starts sending it, like `send_text`.
    ///
    /// # Errors
    /// `SendRefused` for anything but the test chat, an empty or too large
    /// file, a photo that is not JPEG, or a full queue; `Storage` if it
    /// cannot be queued.
    #[allow(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes records by value"
    )]
    pub fn send_file(&self, chat_id: &str, file: OutgoingFile) -> Result<(), CoreError> {
        self.sender.enqueue_file(chat_id, &file)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Sends a voice note recorded as 16 kHz mono 16-bit PCM, little-endian.
    ///
    /// # Errors
    /// `SendRefused` for a chat that is not a person or group, or an empty
    /// or too long recording; `Storage` if it cannot be queued.
    #[allow(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes byte buffers by value"
    )]
    pub fn send_voice_note(&self, chat_id: &str, pcm: Vec<u8>) -> Result<(), CoreError> {
        let samples: Vec<i16> = pcm
            .as_chunks::<2>()
            .0
            .iter()
            .map(|b| i16::from_le_bytes(*b))
            .collect();
        self.sender.enqueue_voice(chat_id, &samples)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Stickers to pick from: the newest seen in any chat, each once.
    ///
    /// # Errors
    /// `Storage` if they cannot be read.
    pub fn recent_stickers(&self) -> Result<Vec<StickerRef>, CoreError> {
        Ok(nimqo_whatsapp::forward::recent_stickers(&self.inbox, 120)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(|(chat_id, seq)| StickerRef { chat_id, seq })
            .collect())
    }

    /// Stickers starred as favorites on the account's devices, the latest
    /// first.
    ///
    /// # Errors
    /// `Storage` if they cannot be read.
    pub fn favorite_stickers(&self) -> Result<Vec<StickerRef>, CoreError> {
        Ok(self
            .inbox
            .favorite_stickers()
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(|(chat_id, seq)| StickerRef { chat_id, seq })
            .collect())
    }

    /// GIFs to pick from: the newest seen in any chat, each once.
    ///
    /// # Errors
    /// `Storage` if they cannot be read.
    pub fn recent_gifs(&self) -> Result<Vec<StickerRef>, CoreError> {
        Ok(nimqo_whatsapp::forward::recent_gifs(&self.inbox, 120)
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(|(chat_id, seq)| StickerRef { chat_id, seq })
            .collect())
    }

    /// Queues a new poll in `chat_id` and starts sending it: `question` and
    /// 2 to 12 distinct `options`, one choice each unless `multiple`.
    ///
    /// # Errors
    /// `SendRefused` with why, or `Storage` if it cannot be queued.
    #[allow(
        clippy::needless_pass_by_value,
        reason = "UniFFI passes sequences by value"
    )]
    pub fn send_poll(
        &self,
        chat_id: &str,
        question: &str,
        options: Vec<String>,
        multiple: bool,
    ) -> Result<(), CoreError> {
        self.sender
            .send_poll(chat_id, question, &options, multiple)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Sends the GIF of message `seq` in `from_chat` to `chat_id`.
    ///
    /// # Errors
    /// As `send_sticker`.
    pub fn send_gif(&self, chat_id: &str, from_chat: &str, seq: i64) -> Result<(), CoreError> {
        self.sender.send_gif(chat_id, from_chat, seq)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Sends the sticker of message `seq` in `from_chat` to `chat_id`.
    ///
    /// # Errors
    /// `SendRefused` for a chat that is not a person or group, or a sticker
    /// that cannot be sent again; `Storage` if it cannot be queued.
    pub fn send_sticker(&self, chat_id: &str, from_chat: &str, seq: i64) -> Result<(), CoreError> {
        self.sender.send_sticker(chat_id, from_chat, seq)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// Queues a text message and starts sending it. Returns once it is
    /// stored; delivery state arrives through `on_chats_changed`.
    ///
    /// # Errors
    /// `reply_to` is the `seq` of the message being replied to.
    ///
    /// `SendRefused` for anything but the test chat, an empty or too long
    /// message, or a full queue; `Storage` if it cannot be queued.
    pub fn send_text(
        &self,
        chat_id: &str,
        text: &str,
        reply_to: Option<i64>,
    ) -> Result<(), CoreError> {
        self.sender.enqueue(chat_id, text, reply_to, None)?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// `send_text` with a link preview the app made (see Settings: off
    /// unless turned on). Dropped when its link is not in the text.
    ///
    /// # Errors
    /// As `send_text`.
    pub fn send_text_with_link(
        &self,
        chat_id: &str,
        text: &str,
        reply_to: Option<i64>,
        link: chats::LinkPreview,
    ) -> Result<(), CoreError> {
        self.sender
            .enqueue(chat_id, text, reply_to, Some(link.into()))?;
        let sender = Arc::clone(&self.sender);
        self.runtime.spawn(async move { sender.flush(false).await });
        Ok(())
    }

    /// The preview a text message carries, as its sender made it.
    #[must_use]
    pub fn link_preview(&self, chat_id: &str, seq: i64) -> Option<chats::LinkPreview> {
        self.inbox.link(chat_id, seq).ok()?.map(Into::into)
    }

    #[must_use]
    pub fn state(&self) -> ConnectionState {
        self.machine.current()
    }

    /// Input from the app's network monitor. A restored path reconnects at
    /// once instead of waiting for upstream's backoff.
    pub fn network_changed(&self, available: bool) {
        self.machine.feed(if available {
            Input::NetworkRestored
        } else {
            Input::NetworkLost
        });
        if available {
            self.reconnect_now();
        }
    }

    /// Asks for an eight-character code to link by phone number instead of a
    /// QR scan. The code arrives through `CoreListener::on_pair_code`, or a
    /// failure through `on_pair_code_error`. Only meaningful while pairing.
    ///
    /// # Errors
    /// `phone_number` is not an international number.
    pub fn request_pair_code(&self, phone_number: &str) -> Result<(), CoreError> {
        let digits = Peer::parse(phone_number)
            .map_err(|_| CoreError::InvalidPhoneNumber)?
            .jid()
            .user
            .to_string();
        if let Ok(mut phone) = self.pair_phone.lock() {
            *phone = Some(digits.clone());
        }
        let client = Arc::clone(&self.client);
        self.runtime
            .spawn(async move { request_code(&client, digits).await });
        Ok(())
    }

    /// People in the address book, by name, to start a chat with.
    ///
    /// # Errors
    /// `Storage` if the store cannot be read.
    pub fn address_book(&self) -> Result<Vec<Contact>, CoreError> {
        Ok(self
            .inbox
            .address_book()
            .map_err(err(|detail| CoreError::Storage { detail }))?
            .into_iter()
            .map(|(id, name)| Contact { id, name })
            .collect())
    }

    /// The chat id of `phone_number`, once WhatsApp confirms the number has
    /// an account.
    ///
    /// # Errors
    /// `InvalidPhoneNumber` for anything but an international number;
    /// `SendRefused` when it isn't on WhatsApp or the check fails.
    pub async fn find_number(&self, phone_number: String) -> Result<String, CoreError> {
        let jid = Peer::parse(&phone_number)
            .map_err(|_| CoreError::InvalidPhoneNumber)?
            .jid();
        let client = Arc::clone(&self.client);
        let found = self
            .runtime
            .spawn(async move { client.contacts().is_on_whatsapp(&[jid]).await })
            .await
            .map_err(|e| CoreError::Storage {
                detail: format!("{e}"),
            })?
            .map_err(|_| CoreError::SendRefused {
                reason: "Couldn't check the number. Check the connection and try again.".into(),
            })?;
        found
            .into_iter()
            .find(|r| r.is_registered)
            .map(|r| r.jid.to_non_ad_string())
            .ok_or_else(|| CoreError::SendRefused {
                reason: "This number isn't on WhatsApp.".into(),
            })
    }

    /// Drops the socket and reconnects without backoff, e.g. after wake from
    /// sleep, when the old socket is likely dead. Does nothing in a terminal
    /// state. Returns immediately.
    pub fn reconnect_now(&self) {
        if self.machine.current().is_terminal() {
            return;
        }
        let client = Arc::clone(&self.client);
        self.runtime.spawn(async move { restart(&client).await });
    }

    /// Unlinks this Mac (when still linked), then destroys the Keychain key
    /// and all local data. Drop the core afterwards and start a new one to
    /// pair again. Blocks for up to the logout and shutdown timeouts.
    ///
    /// # Errors
    /// The key or local files could not be deleted. The session is stopped
    /// either way.
    pub fn log_out_and_reset(&self) -> Result<(), CoreError> {
        const LOGOUT: Duration = Duration::from_secs(10);
        if !self.machine.current().is_terminal() {
            let client = Arc::clone(&self.client);
            let report = self
                .runtime
                .block_on(async { tokio::time::timeout(LOGOUT, client.logout()).await });
            // Not fatal: the phone can still remove the device by hand.
            log::info!("logout sent: {}", report.is_ok());
        }
        self.stop();
        stores::reset(&self.dir).map_err(err(|detail| CoreError::Storage { detail }))?;
        log::info!("local data destroyed");
        // Let the next core in even if Swift still holds this one.
        drop(self.lock.lock().map(|mut l| l.take()));
        Ok(())
    }

    /// Disconnects, waiting at most a few seconds so quitting never hangs.
    /// Safe to call more than once.
    pub fn stop(&self) {
        const GRACE: Duration = Duration::from_secs(3);
        self.attachments.clear_channel_files();
        let handle = self.handle.lock().map_or(None, |mut h| h.take());
        if let Some(handle) = handle {
            let report = self
                .runtime
                .block_on(async { tokio::time::timeout(GRACE, handle.shutdown()).await });
            match report {
                Ok(report) => log::info!("core stopped: {report:?}"),
                Err(_) => log::warn!("core shutdown exceeded {GRACE:?}; exiting anyway"),
            }
        }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        self.stop();
    }
}

fn unix_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// Connects again at once. A pause and resume, not
/// `reconnect_immediately`: that only drops a live socket, so while
/// upstream waits out a backoff after failed attempts it changes nothing,
/// and the wait grows to 15 minutes.
async fn restart(client: &Arc<Client>) {
    client.pause().await;
    client.resume();
}

/// Upstream's backoff doubles up to 15 minutes; a network back without the
/// Mac saying so (DNS was down, a hotspot came back) would wait that long.
/// Still reconnecting after a tick, it tries again every 30 s instead,
/// which leaves an attempt in flight time to finish. Ends with the runtime.
async fn keep_reconnecting(machine: Arc<Machine>, client: Arc<Client>) {
    const EVERY: Duration = Duration::from_secs(30);
    let mut tick = tokio::time::interval(EVERY);
    let mut waited = false;
    loop {
        tick.tick().await;
        let stuck = machine.current() == ConnectionState::Reconnecting;
        if stuck && waited {
            log::info!("still reconnecting; trying again now");
            restart(&client).await;
        }
        waited = stuck;
    }
}

/// Deletes disappearing messages when due, now and then every minute. Ends
/// with the runtime.
async fn purge_expired(inbox: Inbox, attachments: Arc<Attachments>) {
    let mut tick = tokio::time::interval(Duration::from_secs(60));
    let mut round = 0_u64;
    loop {
        tick.tick().await;
        round = round.wrapping_add(1);
        // Images of messages that are gone: at start, then every 15 minutes
        // (deleted-by-sender messages are caught here too).
        if round % 15 == 1 {
            let store = Arc::clone(&attachments);
            match tokio::task::spawn_blocking(move || store.sweep()).await {
                Ok(Ok(0)) => {}
                Ok(Ok(n)) => log::info!("removed {n} image(s) of messages that are gone"),
                Ok(Err(e)) => log::warn!("images not swept: {e:#}"),
                Err(e) => log::warn!("sweep task failed: {e}"),
            }
        }
        let now = unix_now();
        let batch = inbox.clone();
        match tokio::task::spawn_blocking(move || batch.purge_expired(now)).await {
            Ok(Ok(chats)) if !chats.is_empty() => {
                log::info!("removed disappearing messages from {} chat(s)", chats.len());
                inbox.notify_changed(chats);
            }
            Ok(Ok(_)) => {}
            Ok(Err(e)) => log::warn!("expired messages not removed: {e:#}"),
            Err(e) => log::warn!("expiry task failed: {e}"),
        }
    }
}

/// A sticker to pick: the message it came in.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct StickerRef {
    pub chat_id: String,
    pub seq: i64,
}

/// An audio message as its bubble draws it.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct AudioInfo {
    pub seconds: u32,
    /// Recorded as a voice note rather than sent as a file.
    pub voice: bool,
    /// Up to 64 bars, 0 to 100; empty when the sender drew none.
    pub waveform: Vec<u8>,
}

#[derive(uniffi::Record)]
pub struct MessagePicture {
    pub bytes: Vec<u8>,
    /// False while only the thumbnail is stored.
    pub full: bool,
}

/// Position of a message in a chat's timeline.
#[derive(uniffi::Record)]
pub struct Cursor {
    pub timestamp_secs: i64,
    pub seq: i64,
}

struct Session {
    handle: BotHandle,
    client: Arc<Client>,
    lock: File,
    dir: PathBuf,
    inbox: Inbox,
    sender: Arc<outbox::Sender>,
    avatars: Arc<Avatars>,
    attachments: Arc<Attachments>,
    presences: Arc<Presences>,
    calls: Arc<calls::Calls>,
}

async fn open_stores() -> Result<stores::Stores, CoreError> {
    stores::open(Fault::None).await.map_err(|e| {
        if e.downcast_ref::<AlreadyRunning>().is_some() {
            CoreError::AlreadyRunning
        } else {
            CoreError::Storage {
                detail: format!("{e:#}"),
            }
        }
    })
}

async fn connect(
    machine: Arc<Machine>,
    pair_phone: Arc<Mutex<Option<String>>>,
) -> Result<Session, CoreError> {
    let mut stores = open_stores().await?;
    let listener = Arc::clone(&machine.listener);
    stores
        .inbox
        .set_on_commit(Arc::new(move |chats| listener.on_chats_changed(chats)));
    let inbox = stores.inbox.clone();
    let history_inbox = stores.inbox.clone();
    // Handlers are built before the client exists; they find the sender here.
    let sender_cell: Arc<OnceLock<Arc<outbox::Sender>>> = Arc::default();
    let sender_listener = Arc::clone(&machine.listener);
    let sender_machine = Arc::clone(&machine);
    let (on_qr, on_code, on_code_err) = (
        Arc::clone(&machine),
        Arc::clone(&machine),
        Arc::clone(&machine),
    );
    let avatars = Arc::new(Avatars::new(
        stores.inbox.clone(),
        stores.avatar_dir.clone(),
        stores.media_key.clone(),
    ));
    let attachments = Arc::new(Attachments::new(
        stores.inbox.clone(),
        stores.media_dir.clone(),
        stores.media_key.clone(),
    ));
    let presences = Arc::<Presences>::default();
    let calls = Arc::new(calls::Calls::new(inbox.clone()));
    let builder = call_handlers(Bot::builder(), inbox.clone(), Arc::clone(&calls));
    let builder = message_handlers(builder, history_inbox.clone(), &sender_cell, &avatars);
    let builder = presence_handlers(builder, history_inbox, Arc::clone(&presences));
    let bot = state_handlers(builder, machine)
        .with_backend(stores.protocol)
        // The name the phone shows under Linked devices; the library's
        // default is "rust". Sent only when linking.
        .with_device_props(
            whatsapp_rust::wacore::store::DevicePropsOverride::new().with_os("NIMQO"),
        )
        .with_inbound_durability_hook(stores.inbox)
        .with_event_delivery(EVENT_DELIVERY)
        .on_qr_code(move |code, timeout| {
            on_qr.feed(Input::QrShown);
            on_qr.listener.on_qr(code, timeout.as_secs());
            async {}
        })
        .on_pair_code(move |code, timeout| {
            on_code.listener.on_pair_code(code, timeout.as_secs());
            async {}
        })
        .on_pair_code_error(move |e, _| {
            // Only the classification is logged; the message can echo the number.
            log::warn!("pair code refused: {:?}", e.rejection);
            on_code_err.listener.on_pair_code_error(
                e.rejection.is_some_and(PairCodeRejection::is_throttled),
                e.backoff.map(|d| d.as_secs()),
            );
            async {}
        })
        .on_pair_code_refresh(move |_, client| {
            let phone = pair_phone.lock().ok().and_then(|p| p.clone());
            async move {
                if let Some(phone) = phone {
                    request_code(&client, phone).await;
                }
            }
        })
        .build()
        .await
        .map_err(err(|detail| CoreError::Startup { detail }))?;
    let client = bot.client();
    let sender = Arc::new(outbox::Sender::new(
        inbox.clone(),
        Arc::clone(&client),
        sender_listener,
        Arc::clone(&attachments),
        Box::new(move || sender_machine.current() == ConnectionState::Connected),
    ));
    let _ = sender_cell.set(Arc::clone(&sender));
    Ok(Session {
        handle: bot.spawn(),
        client,
        lock: stores.lock,
        dir: stores.dir,
        inbox,
        sender,
        avatars,
        attachments,
        presences,
        calls,
    })
}

/// Connection events feed the state machine.
fn state_handlers<B, T, H, R>(
    builder: whatsapp_rust::bot::BotBuilder<B, T, H, R>,
    machine: Arc<Machine>,
) -> whatsapp_rust::bot::BotBuilder<B, T, H, R> {
    builder.on_event_for(
        &[
            EventKind::Connected,
            EventKind::Disconnected,
            EventKind::LoggedOut,
            EventKind::StreamReplaced,
            EventKind::TemporaryBan,
            EventKind::ClientOutdated,
            EventKind::ConnectFailure,
            EventKind::StreamError,
            EventKind::PairingQrCodesExhausted,
            EventKind::PairSuccess,
        ],
        move |event, _| {
            if let Some(input) = input_from(&event) {
                machine.feed(input);
            }
            async {}
        },
    )
}

/// Ringing, answers, and hang-ups for 1:1 calls, and the phone's call log.
fn call_handlers<B, T, H, R>(
    builder: whatsapp_rust::bot::BotBuilder<B, T, H, R>,
    inbox: Inbox,
    calls: Arc<calls::Calls>,
) -> whatsapp_rust::bot::BotBuilder<B, T, H, R> {
    builder.on_event_for(
        &[
            EventKind::IncomingCall,
            EventKind::MissedCall,
            EventKind::CallEndedElsewhere,
            EventKind::CallLogSync,
            EventKind::CallLogHistory,
        ],
        move |event, client| {
            let (inbox, calls) = (inbox.clone(), Arc::clone(&calls));
            async move { calls.on_event(&client, &inbox, &event).await }
        },
    )
}

/// Contacts' online and typing state, for the chat header.
fn presence_handlers<B, T, H, R>(
    builder: whatsapp_rust::bot::BotBuilder<B, T, H, R>,
    inbox: Inbox,
    presences: Arc<Presences>,
) -> whatsapp_rust::bot::BotBuilder<B, T, H, R> {
    builder.on_event_for(
        &[EventKind::Presence, EventKind::ChatPresence],
        move |event, client| {
            let (inbox, presences) = (inbox.clone(), Arc::clone(&presences));
            async move {
                let chat = match &*event {
                    Event::Presence(p) => {
                        let chat = lids::phone_chat(&inbox, &client, &p.from).await;
                        let online = matches!(p.status, PresenceStatus::Available);
                        presences.set_online(&chat, online, p.last_seen.map(|t| t.timestamp()));
                        chat
                    }
                    Event::ChatPresence(c) => {
                        let active = !matches!(c.state, ChatActivity::Idle);
                        let recording = matches!(c.state, ChatActivity::RecordingAudio);
                        let (chat, typist) = if c.source.is_group {
                            (
                                c.source.chat.to_string(),
                                Some(c.source.sender.user.to_string()),
                            )
                        } else {
                            (
                                lids::phone_chat(&inbox, &client, &c.source.chat).await,
                                None,
                            )
                        };
                        presences.set_activity(&chat, active, recording, typist, unix_now());
                        chat
                    }
                    _ => return,
                };
                inbox.notify_changed(vec![chat]);
            }
        },
    )
}

/// History import, delivery receipts, and outbox flushes on connect.
fn message_handlers<B, T, H, R>(
    builder: whatsapp_rust::bot::BotBuilder<B, T, H, R>,
    history_inbox: Inbox,
    sender_cell: &Arc<OnceLock<Arc<outbox::Sender>>>,
    avatars: &Arc<Avatars>,
) -> whatsapp_rust::bot::BotBuilder<B, T, H, R> {
    let (on_up, on_receipt) = (Arc::clone(sender_cell), Arc::clone(sender_cell));
    let (pictures, picture_inbox) = (Arc::clone(avatars), history_inbox.clone());
    builder
        .on_event_for(&[EventKind::PictureUpdate], move |event, client| {
            let (avatars, inbox) = (Arc::clone(&pictures), picture_inbox.clone());
            async move {
                let Event::PictureUpdate(update) = &*event else {
                    return;
                };
                log::info!("picture changed notification (removed: {})", update.removed);
                let chat = lids::phone_chat(&inbox, &client, &update.jid).await;
                // Fetch the new one now; refresh reports the change itself.
                if let Err(e) = avatars.invalidate(&chat) {
                    log::warn!("avatar not invalidated: {e:#}");
                }
                if let Err(e) = avatars.refresh(&client, &chat, unix_now()).await {
                    log::info!("avatar not fetched: {e:#}");
                }
            }
        })
        .on_event_for(&[EventKind::HistorySync], move |event, client| {
            let inbox = history_inbox.clone();
            async move {
                let Event::HistorySync(sync) = &*event else {
                    return;
                };
                let sync = (**sync).clone(); // shares the compressed bytes
                // Inflating and storing a chunk takes a while; keep it off
                // the protocol runtime.
                let importer = inbox.clone();
                match tokio::task::spawn_blocking(move || history::import(&importer, &sync)).await {
                    Ok(Ok(n)) => log::info!("history chunk stored: {n} message(s)"),
                    Ok(Err(e)) => log::warn!("history chunk not stored: {e:#}"),
                    Err(e) => log::warn!("history import panicked: {e}"),
                }
                // History teaches upstream LID numbers; merge what it learned.
                lids::resolve(&inbox, &client).await;
            }
        })
        .on_event_for(
            &[
                EventKind::Receipt,
                EventKind::ServerAck,
                EventKind::MarkChatAsReadUpdate,
                EventKind::ContactUpdate,
                EventKind::ContactRemoved,
                EventKind::DisappearingModeChanged,
                EventKind::AppStateSyncFailed,
                EventKind::MuteUpdate,
                EventKind::PinUpdate,
                EventKind::ArchiveUpdate,
                EventKind::StarUpdate,
                EventKind::DeleteMessageForMeUpdate,
                EventKind::FavoriteStickerUpdate,
                EventKind::GroupUpdate,
            ],
            move |event, _| {
                let sender = on_receipt.get().cloned();
                async move {
                    if let Some(sender) = sender {
                        on_account_event(sender, &event).await;
                    }
                }
            },
        )
        .on_connected(move |_| {
            // Messages queued while offline go out now.
            let sender = on_up.get().cloned();
            async move {
                if let Some(sender) = sender {
                    sender.connection_restarted();
                    sender.flush(true).await;
                    // Also cleans up chats stored by LID in earlier runs.
                    lids::resolve(&sender.inbox, &sender.client).await;
                    sender.load_contacts_once().await;
                    sender.load_mutes_once().await;
                    sender.load_flags_once().await;
                    sender.load_favorite_stickers_once().await;
                }
            }
        })
}

/// Receipts and app-state changes synced from the account's other devices.
async fn on_account_event(sender: Arc<outbox::Sender>, event: &Event) {
    match event {
        Event::Receipt(receipt) => sender.on_receipt(receipt).await,
        Event::ServerAck(ack) => sender.on_server_ack(ack),
        Event::ContactUpdate(c) => {
            let a = &c.action;
            let name = a.full_name.as_deref().or(a.first_name.as_deref());
            sender
                .on_contact(&c.jid, name.unwrap_or(""), a.pn_jid.as_deref())
                .await;
        }
        Event::ContactRemoved(c) => sender.on_contact(&c.jid, "", None).await,
        // Collection names only, never their content.
        Event::AppStateSyncFailed(f) => log::warn!(
            "app state not synced: fatal {:?}, retryable {:?}, skipped {:?}",
            f.fatal,
            f.retryable,
            f.skipped
        ),
        Event::DisappearingModeChanged(d) => {
            log::info!("disappearing mode changed: {}s", d.duration);
            sender.on_timer(&d.from, d.duration).await;
        }
        Event::MuteUpdate(m) => {
            let a = &m.action;
            sender
                .on_mute(&m.jid, a.muted.unwrap_or(false), a.mute_end_timestamp)
                .await;
        }
        Event::PinUpdate(p) => {
            let at = p.timestamp.timestamp_millis();
            sender
                .on_pin(&p.jid, p.action.pinned.unwrap_or(false), at)
                .await;
        }
        Event::ArchiveUpdate(a) => {
            sender
                .on_archive(&a.jid, a.action.archived.unwrap_or(false))
                .await;
        }
        Event::StarUpdate(s) => {
            sender
                .on_star(
                    &s.chat_jid,
                    &s.message_id,
                    s.action.starred.unwrap_or(false),
                )
                .await;
        }
        Event::DeleteMessageForMeUpdate(d) => {
            sender
                .on_deleted_for_me(&d.chat_jid, &d.message_id, d.from_me)
                .await;
        }
        Event::GroupUpdate(g) => sender.on_group_update(&g.group_jid, &g.action),
        Event::FavoriteStickerUpdate(f) => {
            sender.on_favorite_sticker(&f.filehash, &f.action, f.timestamp.timestamp());
        }
        Event::MarkChatAsReadUpdate(update) => {
            let range = update.action.message_range.as_option();
            sender
                .on_chat_marked_read(
                    &update.jid,
                    update.action.read.unwrap_or(false),
                    range.and_then(|r| r.last_message_timestamp),
                )
                .await;
        }
        _ => {}
    }
}

/// The default 256-event mailbox drops the newest event when full, and the
/// address book arrives as thousands of contact events at once.
/// ponytail: a large fixed buffer; store contacts in a backend hook if an
/// address book ever outgrows it.
const EVENT_DELIVERY: whatsapp_rust::EventDelivery =
    whatsapp_rust::EventDelivery::BoundedConcurrent {
        capacity: 50_000,
        max_concurrency: 16,
    };

/// Failures are reported through the `PairingCodeError` event, so the
/// returned error carries nothing new.
async fn request_code(client: &Arc<Client>, phone_number: String) {
    let options = PairCodeOptions {
        phone_number,
        ..PairCodeOptions::default()
    };
    if client.pair_with_code(options).await.is_err() {
        log::warn!("pair code request failed");
    }
}

/// Maps the upstream events plan 10.1 names onto state machine inputs.
fn input_from(event: &Event) -> Option<Input> {
    Some(match event {
        // Linked. Upstream announces Connected only once the first history
        // sync is through, which after a fresh pairing can take minutes;
        // the session is live already and history fills in as it comes.
        Event::Connected(_) | Event::PairSuccess(_) => Input::Connected,
        Event::Disconnected(_) => Input::Disconnected,
        Event::LoggedOut(_) => Input::LoggedOut,
        Event::StreamReplaced(_) => Input::StreamReplaced,
        Event::TemporaryBan(ban) => Input::TemporaryBan {
            expires_in_secs: u64::try_from(ban.expire.num_seconds()).unwrap_or(0),
        },
        Event::ClientOutdated(_) => Input::ClientOutdated,
        Event::ConnectFailure(f) => Input::ConnectFailure {
            logged_out: f.reason.is_logged_out(),
            retry: f.reason.should_reconnect(),
            reason: format!("{:?}", f.reason),
        },
        Event::StreamError(e) => Input::StreamError {
            code: e.code.clone(),
        },
        Event::PairingQrCodesExhausted(_) => Input::QrExhausted,
        _ => return None,
    })
}

/// Sends NIMQO's own `log` records to the unified log (Console.app,
/// `/usr/bin/log stream`). `os_log` stores them as public, so upstream records
/// are dropped: they can carry JIDs, which are phone numbers.
fn init_logging() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        log::set_max_level(log::LevelFilter::Info);
        // Fails only if another logger is already installed; keep that one.
        let _ = log::set_boxed_logger(Box::new(NimqoOnly(oslog::OsLogger::new("app.nimqo.core"))));
    });
}

struct NimqoOnly(oslog::OsLogger);

impl log::Log for NimqoOnly {
    fn enabled(&self, metadata: &log::Metadata<'_>) -> bool {
        let target = metadata.target();
        if target.starts_with("nimqo") {
            return metadata.level() <= log::Level::Info;
        }
        // Why a call was dropped, or a reconnect stalled, lives upstream; those
        // warnings come through with numbers masked.
        let upstream = [
            "whatsapp_rust::handlers::call",
            "whatsapp_rust::voip",
            "wacore::voip",
            "whatsapp_rust::client",
            "whatsapp_rust::keepalive",
            "whatsapp_rust::socket",
        ];
        upstream.iter().any(|c| target.starts_with(c)) && metadata.level() <= log::Level::Warn
    }

    fn log(&self, record: &log::Record<'_>) {
        if !self.enabled(record.metadata()) {
            return;
        }
        if record.target().starts_with("nimqo") {
            return self.0.log(record);
        }
        let masked = mask_numbers(&record.args().to_string());
        self.0.log(
            &log::Record::builder()
                .metadata(record.metadata().clone())
                .args(format_args!("{masked}"))
                .build(),
        );
    }

    fn flush(&self) {}
}

/// Runs of five or more digits (phone numbers, LIDs) become `#`.
fn mask_numbers(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut digits = String::new();
    for c in text.chars().chain(std::iter::once('\0')) {
        if c.is_ascii_digit() {
            digits.push(c);
            continue;
        }
        out.push_str(if digits.len() >= 5 { "#" } else { &digits });
        digits.clear();
        if c != '\0' {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_nimqo_targets_reach_the_unified_log() {
        use log::Log;
        let logger = NimqoOnly(oslog::OsLogger::new("test"));
        let meta = |target| {
            log::Metadata::builder()
                .target(target)
                .level(log::Level::Info)
                .build()
        };
        assert!(logger.enabled(&meta("nimqo_ffi")));
        assert!(!logger.enabled(&meta("whatsapp_rust::client")));
        // Upstream call records only at warn, and masked.
        assert!(!logger.enabled(&meta("whatsapp_rust::handlers::call")));
        assert_eq!(
            mask_numbers("call 00af12 from 6281234567890@s.whatsapp.net:12 x"),
            "call 00af12 from #@s.whatsapp.net:12 x"
        );
    }
}
