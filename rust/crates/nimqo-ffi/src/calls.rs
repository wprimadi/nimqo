//! One voice or video call at a time, with a person or a group. Swift brings the microphone and
//! camera and plays what comes back; this side rings, answers, and keeps the
//! call's state. Media crosses the FFI as 16 kHz mono PCM and Annex-B H.264.
//! Logs name call ids only, never who is calling.

use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use nimqo_whatsapp::calllog::{self, Call, Outcome};
use nimqo_whatsapp::inbox::{Inbox, ME};
use nimqo_whatsapp::lids;
use whatsapp_rust::Client;
use whatsapp_rust::Jid;
use whatsapp_rust::prelude::wa;
use whatsapp_rust::types::call::{CallAction, IncomingCall};
use whatsapp_rust::types::events::Event;
use whatsapp_rust::types::group_call::GroupCallUpdate;
use whatsapp_rust::voip::{
    CallEvent, CallHandle, KeyframeUrgency, ScreenShareState, VideoFrame, VideoState,
    VideoUpgradeToken,
};

use crate::{Core, CoreError};

/// How long an unanswered outgoing call rings before giving up.
const RING_SECS: u64 = 60;

/// Why a call ended, so the app can say so.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CallEnd {
    /// This side hung up or declined.
    Local,
    /// The other side hung up.
    Remote,
    /// The other side declined.
    Declined,
    /// Nobody answered.
    NoAnswer,
    /// The caller gave up before it was answered here.
    Missed,
    /// Answered or declined on another of this account's devices.
    Elsewhere,
    /// The connection could not be set up or was lost.
    Failed,
}

/// The other side's camera.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum PeerVideo {
    /// They ask to turn this into a video call.
    Requested,
    On,
    Off,
}

/// Someone in a group call.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CallParticipant {
    /// What their video is tagged with in `on_call_video`.
    pub id: String,
    /// Their chat, for a name and picture.
    pub chat: String,
    /// In the call, not still being rung.
    pub joined: bool,
}

/// Implemented in Swift. Called from Rust worker threads; the media
/// callbacks come many times a second.
#[uniffi::export(with_foreign)]
pub trait CallListener: Send + Sync {
    /// Someone is calling; ring until `on_call_ended` names this call.
    fn on_call_ringing(&self, call_id: String, chat_id: String, video: bool);
    /// Both sides are talking.
    fn on_call_connected(&self, call_id: String);
    fn on_call_ended(&self, call_id: String, reason: CallEnd);
    /// A call rang while NIMQO could not answer it.
    fn on_missed_call(&self, chat_id: String);
    fn on_peer_video(&self, call_id: String, state: PeerVideo);
    /// The other side started (`true`) or stopped sharing its screen, in
    /// place of its camera.
    fn on_peer_screen(&self, call_id: String, sharing: bool);
    /// 16 kHz mono samples to play.
    fn on_call_audio(&self, samples: Vec<i16>);
    /// One Annex-B access unit; `orientation` is in quarter turns. `from`
    /// names the participant in a group call, `None` in a 1:1 call.
    fn on_call_video(&self, frame: Vec<u8>, keyframe: bool, orientation: u8, from: Option<String>);
    /// Everyone else in a group call, whenever that changes.
    fn on_call_participants(&self, call_id: String, participants: Vec<CallParticipant>);
    /// The next encoded frame must be a keyframe.
    fn on_keyframe_needed(&self);
}

struct Active {
    handle: CallHandle,
    mic: async_channel::Sender<Vec<i16>>,
    camera: Option<async_channel::Sender<Vec<u8>>>,
    /// The peer's pending ask to turn video on.
    video_request: Option<VideoUpgradeToken>,
    outgoing: bool,
    connected: bool,
    /// A group call: one person leaving does not end it.
    group: bool,
    client: Arc<Client>,
}

/// What the chat's timeline gets when the call ends.
struct Log {
    id: String,
    chat: String,
    video: bool,
    outgoing: bool,
    started: i64,
    connected: Option<i64>,
}

impl Log {
    /// `None` when another device took the call: the phone's record says how.
    fn into_call(self, reason: CallEnd) -> Option<Call> {
        let outcome = match (reason, self.connected, self.outgoing) {
            (CallEnd::Elsewhere, ..) => return None,
            (_, Some(_), _) => Outcome::Connected,
            (CallEnd::Declined, ..) | (CallEnd::Local, None, false) => Outcome::Declined,
            (CallEnd::Failed, ..) => Outcome::Failed,
            (_, None, true) => Outcome::NoAnswer,
            (_, None, false) => Outcome::Missed,
        };
        Some(Call {
            sender: if self.outgoing {
                ME.to_owned()
            } else {
                self.chat.clone()
            },
            chat: self.chat,
            id: self.id,
            video: self.video,
            outcome,
            started: self.started,
            secs: self.connected.map_or(0, |c| now() - c),
        })
    }
}

fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

#[derive(Default)]
struct State {
    ringing: Option<IncomingCall>,
    /// A call being placed or answered, before its handle exists.
    starting: bool,
    active: Option<Active>,
    log: Option<Log>,
}

pub(crate) struct Calls {
    listener: Mutex<Option<Arc<dyn CallListener>>>,
    state: Mutex<State>,
    inbox: Inbox,
}

/// Files a call in its chat, off the async threads.
fn file(inbox: &Inbox, call: Call) {
    let inbox = inbox.clone();
    tokio::task::spawn_blocking(move || {
        if let Err(e) = calllog::store(&inbox, call) {
            log::warn!("call not filed: {e:#}");
        }
    });
}

fn refused(reason: &str) -> CoreError {
    CoreError::SendRefused {
        reason: reason.into(),
    }
}

/// The engine's channels: what Swift captures goes in, what it plays comes
/// out. Capture sender, engine source, engine sink.
type Pair<In, Out> = (
    async_channel::Sender<In>,
    async_channel::Receiver<In>,
    async_channel::Sender<Out>,
);

fn audio_pair(listener: Arc<dyn CallListener>) -> Pair<Vec<i16>, Vec<i16>> {
    // Small queues: late audio is worse than dropped audio.
    let (mic_tx, mic_rx) = async_channel::bounded(8);
    let (speaker_tx, speaker_rx) = async_channel::bounded::<Vec<i16>>(16);
    tokio::spawn(async move {
        while let Ok(samples) = speaker_rx.recv().await {
            listener.on_call_audio(samples);
        }
    });
    (mic_tx, mic_rx, speaker_tx)
}

/// The group a group offer names, only when the caller is in it: an offer
/// can name any group, and the call would ring as if it came from there.
async fn caller_group(client: &Client, group: &Jid, from: &Jid) -> Option<String> {
    let meta = client.groups().fetch_metadata(group).await.ok()?;
    let member = meta.participants.iter().any(|p| {
        [Some(&p.jid), p.phone_number.as_ref(), p.lid.as_ref()]
            .into_iter()
            .flatten()
            .any(|j| j.user == from.user)
    });
    if !member {
        log::warn!("group offer from someone not in the group: shown as theirs");
    }
    member.then(|| group.to_non_ad_string())
}

fn video_pair(listener: Arc<dyn CallListener>) -> Pair<Vec<u8>, VideoFrame> {
    let (camera_tx, camera_rx) = async_channel::bounded(4);
    let (screen_tx, screen_rx) = async_channel::bounded::<VideoFrame>(8);
    tokio::spawn(async move {
        while let Ok(frame) = screen_rx.recv().await {
            let from = frame.sender.as_ref().map(Jid::to_non_ad_string);
            listener.on_call_video(frame.data, frame.keyframe, frame.orientation, from);
        }
    });
    (camera_tx, camera_rx, screen_tx)
}

/// Counts only, for telling a network stall from a decoder one.
fn log_video_stats(call_id: &str, handle: &CallHandle) {
    let s = handle.media_stats();
    if s.video_rtp_received == 0 {
        return;
    }
    log::info!(
        "call {call_id} video: rtp {} lost {} stale {}, units {} no-marker {} evicted {}, \
         fragment gaps {}, sink dropped {}, keyframe asks {}, dropped before the engine {}; \
         fec: repairs {} recovered {} parity ok {} bad {}, two lost {} late {} rejected {}, \
         gaps skipped {} ({} packets) late {}; other payload types {} (last {}); \
         ssrc switches {} (partial dropped {}), retired ignored {}; all rtp {} srtp failed {} \
         (video {}) sframe failed {}, auxiliary {}, unclassified {}, unusable {}, oversize {}, \
         orphan fragments {}, timestamp boundary drops {}, shared timestamp {}",
        s.video_rtp_received,
        s.video_rtp_lost,
        s.video_rtp_stale_timestamp,
        s.video_access_units_completed,
        s.video_access_units_without_marker,
        s.video_access_units_evicted,
        s.video_fu_dropped_sequence_gap,
        s.video_sink_dropped,
        s.peer_keyframe_requests,
        s.inbound_pipe_dropped,
        s.video_fec_repairs_received,
        s.video_fec_recovered,
        s.video_fec_parity_matched,
        s.video_fec_parity_mismatched,
        s.video_fec_insufficient,
        s.video_fec_late,
        s.video_fec_rejected,
        s.video_gaps_skipped,
        s.video_packets_skipped,
        s.video_packets_late,
        s.rtp_payload_type_unexpected,
        s.last_unexpected_payload_type,
        s.video_ssrc_switches,
        s.video_ssrc_switch_partial_dropped,
        s.video_retired_ssrc_ignored,
        s.rtp_received,
        s.srtp_unprotect_failed,
        s.video_srtp_unprotect_failed,
        s.sframe_decrypt_failed,
        s.auxiliary_rtp_authenticated,
        s.relay_packet_unclassified,
        s.video_payload_unusable,
        s.video_nal_oversize_dropped,
        s.video_fu_orphan_fragments,
        s.video_fu_dropped_timestamp_boundary,
        s.video_access_units_shared_timestamp,
    );
}

impl Calls {
    pub(crate) fn new(inbox: Inbox) -> Self {
        Self {
            listener: Mutex::default(),
            state: Mutex::default(),
            inbox,
        }
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn listener(&self) -> Option<Arc<dyn CallListener>> {
        self.listener.lock().ok().and_then(|l| l.clone())
    }

    fn handle(&self) -> Option<CallHandle> {
        self.lock().active.as_ref().map(|a| a.handle.clone())
    }

    fn busy(state: &State) -> bool {
        state.ringing.is_some() || state.starting || state.active.is_some()
    }

    /// Reports the end once, whoever notices first.
    fn finish(&self, call_id: &str, reason: CallEnd) {
        let (ended, handle, log) = {
            let mut state = self.lock();
            let log = state.log.take_if(|l| l.id == call_id);
            let (ended, handle) = if state
                .active
                .as_ref()
                .is_some_and(|a| a.handle.call_id() == call_id)
            {
                (true, state.active.take().map(|a| a.handle))
            } else if state
                .ringing
                .as_ref()
                .is_some_and(|r| r.action.call_id() == call_id)
            {
                state.ringing = None;
                (true, None)
            } else {
                (false, None)
            };
            (ended, handle, log)
        };
        if let Some(call) = log.and_then(|l| l.into_call(reason)) {
            file(&self.inbox, call);
        }
        if ended {
            log::info!("call {call_id} ended: {reason:?}");
            if let Some(handle) = handle {
                log_video_stats(call_id, &handle);
            }
            if let Some(listener) = self.listener() {
                listener.on_call_ended(call_id.to_owned(), reason);
            }
        }
    }

    fn mark_connected(&self, call_id: &str) {
        let first = {
            let mut state = self.lock();
            if let Some(l) = state.log.as_mut().filter(|l| l.id == call_id) {
                l.connected.get_or_insert_with(now);
            }
            match state.active.as_mut() {
                Some(a) if a.handle.call_id() == call_id && !a.connected => {
                    a.connected = true;
                    true
                }
                _ => false,
            }
        };
        if first && let Some(listener) = self.listener() {
            listener.on_call_connected(call_id.to_owned());
        }
    }

    /// Keeps the handle and follows the call until it ends.
    fn adopt(
        self: &Arc<Self>,
        client: Arc<Client>,
        handle: CallHandle,
        media: (
            async_channel::Sender<Vec<i16>>,
            Option<async_channel::Sender<Vec<u8>>>,
        ),
        outgoing: bool,
        group: bool,
    ) {
        let (mic, camera) = media;
        let call_id = handle.call_id().to_owned();
        let events = handle.take_events();
        {
            let mut state = self.lock();
            state.starting = false;
            state.active = Some(Active {
                handle: handle.clone(),
                mic,
                camera,
                video_request: None,
                outgoing,
                connected: false,
                group,
                client,
            });
        }
        let calls = Arc::clone(self);
        let id = call_id.clone();
        tokio::spawn(async move {
            handle.wait_ended().await;
            calls.finish(&id, CallEnd::Remote);
        });
        if let Some(mut events) = events {
            let calls = Arc::clone(self);
            tokio::spawn(async move {
                // ponytail: counts only, to learn what a group's server feeds back (NACK, REMB…).
                let mut rtcp = std::collections::BTreeMap::<(u8, u8), u32>::new();
                while let Ok(event) = events.recv().await {
                    if let CallEvent::RtcpReceived {
                        packet_types,
                        feedback,
                        ..
                    } = &event
                    {
                        let kinds = packet_types.iter().map(|&pt| (pt, 0));
                        let kinds =
                            kinds.chain(feedback.iter().map(|f| (f.packet_type, f.fmt + 1)));
                        for kind in kinds {
                            *rtcp.entry(kind).or_default() += 1;
                        }
                    }
                    calls.on_media_event(&call_id, event).await;
                }
                log::info!("call {call_id} rtcp in (type, feedback fmt+1): {rtcp:?}");
            });
        }
    }

    async fn on_media_event(&self, call_id: &str, event: CallEvent) {
        let listener = self.listener();
        match event {
            CallEvent::MediaConnected => {
                // An outgoing call's relay connects while it still rings.
                let incoming = self
                    .lock()
                    .active
                    .as_ref()
                    .is_some_and(|a| a.handle.call_id() == call_id && !a.outgoing);
                if incoming {
                    self.mark_connected(call_id);
                }
            }
            CallEvent::MediaSetupFailed(_)
            | CallEvent::RelayAllocateFailed(_)
            | CallEvent::RelayAllocateTimedOut
            | CallEvent::RelayReconnectTimedOut => {
                log::warn!("call {call_id} media lost");
                if let Some(handle) = self.handle() {
                    let _ = handle.terminate().await;
                }
                self.finish(call_id, CallEnd::Failed);
            }
            CallEvent::PeerVideoStateChanged {
                state,
                upgrade_token,
                ..
            } => {
                let shown = match state {
                    VideoState::UpgradeRequest | VideoState::UpgradeRequestV2 => {
                        let asked = upgrade_token.is_some();
                        if let Some(a) = self.lock().active.as_mut() {
                            a.video_request = upgrade_token;
                        }
                        asked.then_some(PeerVideo::Requested)
                    }
                    VideoState::UpgradeAccept | VideoState::Enabled => Some(PeerVideo::On),
                    VideoState::Stopped
                    | VideoState::Disabled
                    | VideoState::UpgradeReject
                    | VideoState::UpgradeRejectByTimeout
                    | VideoState::UpgradeCancel
                    | VideoState::UpgradeCancelByTimeout
                    | VideoState::Error => {
                        if let Some(a) = self.lock().active.as_mut() {
                            a.video_request = None;
                        }
                        Some(PeerVideo::Off)
                    }
                    _ => None,
                };
                if let (Some(shown), Some(listener)) = (shown, listener) {
                    listener.on_peer_video(call_id.to_owned(), shown);
                }
            }
            CallEvent::ScreenShareChanged { screen_share, .. } => {
                if let Some(listener) = listener {
                    let sharing = screen_share.state == ScreenShareState::Started;
                    log::info!("call {call_id} peer screen share: {sharing}");
                    listener.on_peer_screen(call_id.to_owned(), sharing);
                }
            }
            CallEvent::GroupUpdated(update) => self.on_group_update(call_id, &update).await,
            CallEvent::VideoKeyframeNeeded => {
                if let Some(listener) = listener {
                    listener.on_keyframe_needed();
                }
            }
            _ => {}
        }
    }

    /// Tells the app who else is in a group call; the call counts as
    /// connected once someone has joined.
    async fn on_group_update(&self, call_id: &str, update: &GroupCallUpdate) {
        let Some(client) = self
            .lock()
            .active
            .as_ref()
            .filter(|a| a.handle.call_id() == call_id)
            .map(|a| Arc::clone(&a.client))
        else {
            return;
        };
        let me: Vec<Jid> = [client.pn(), client.lid()].into_iter().flatten().collect();
        let mut participants = Vec::new();
        for p in &update.participants {
            let mine = [Some(&p.jid), p.pn.as_ref()]
                .into_iter()
                .flatten()
                .any(|j| me.iter().any(|m| m.user == j.user));
            if mine {
                continue;
            }
            let chat = match &p.pn {
                Some(pn) => pn.to_non_ad_string(),
                None => lids::phone_chat(&self.inbox, &client, &p.jid).await,
            };
            participants.push(CallParticipant {
                id: p.jid.to_non_ad_string(),
                chat,
                joined: p.state.as_deref() == Some("connected"),
            });
        }
        if participants.iter().any(|p| p.joined) {
            self.mark_connected(call_id);
        }
        if let Some(listener) = self.listener() {
            listener.on_call_participants(call_id.to_owned(), participants);
        }
    }

    /// Whether the call going on is a group call.
    fn in_group_call(&self, call_id: &str) -> bool {
        self.lock()
            .active
            .as_ref()
            .is_some_and(|a| a.group && a.handle.call_id() == call_id)
    }

    /// Call signaling from the account's event stream.
    pub(crate) async fn on_event(&self, client: &Arc<Client>, inbox: &Inbox, event: &Event) {
        match event {
            Event::IncomingCall(call) => self.on_signal(client, inbox, call).await,
            Event::CallEndedElsewhere(e) => self.finish(&e.call_id, CallEnd::Elsewhere),
            Event::MissedCall(m) => {
                self.finish(&m.call_id, CallEnd::Missed);
                let chat = lids::phone_chat(inbox, client, &m.from).await;
                if let Some(listener) = self.listener() {
                    listener.on_missed_call(chat);
                }
            }
            Event::CallLogSync(e) => {
                let id = Some(e.call_id.as_str());
                self.file_phone_call(
                    client,
                    &e.record,
                    Some(&e.call_creator_jid),
                    Some(e.from_me),
                    id,
                )
                .await;
            }
            Event::CallLogHistory(e) => {
                let creator = e.call_creator_jid.as_ref();
                self.file_phone_call(client, &e.record, creator, e.from_me, None)
                    .await;
            }
            _ => {}
        }
    }

    /// A call the phone recorded: placed or taken there, or rung here while
    /// NIMQO was closed.
    async fn file_phone_call(
        &self,
        client: &Client,
        record: &wa::CallLogRecord,
        creator: Option<&Jid>,
        from_me: Option<bool>,
        id: Option<&str>,
    ) {
        let Some(from_me) = from_me else { return };
        let (Some(id), Some(outcome), Some(started), Some(peer)) = (
            id.or(record.call_id.as_deref()),
            Outcome::of(record.call_result, from_me),
            calllog::started_of(record),
            calllog::peer_of(record, creator, from_me),
        ) else {
            return;
        };
        let chat = lids::phone_chat(&self.inbox, client, &peer).await;
        let sender = match (from_me, creator) {
            (true, _) => ME.to_owned(),
            (false, Some(c)) if record.group_jid.is_some() => {
                lids::phone_chat(&self.inbox, client, c).await
            }
            (false, _) => chat.clone(),
        };
        let call = Call {
            chat,
            sender,
            id: id.to_owned(),
            video: record.is_video.unwrap_or(false),
            outcome,
            started,
            secs: record.duration.unwrap_or(0),
        };
        file(&self.inbox, call);
    }

    async fn on_signal(&self, client: &Arc<Client>, inbox: &Inbox, call: &IncomingCall) {
        log::info!(
            "call {} signal {} (group {}, offline {})",
            call.action.call_id(),
            call.action.wire_tag(),
            call.group.is_some(),
            call.offline
        );
        match &call.action {
            CallAction::Offer {
                call_id,
                is_video,
                group_jid,
                ..
            } => {
                if call.offline {
                    return;
                }
                if Self::busy(&self.lock()) {
                    log::info!("call {call_id} declined: already in a call");
                    let _ = client.voip().reject(call).await;
                    return;
                }
                self.lock().ringing = Some(call.clone());
                log::info!("call {call_id} ringing (group: {})", group_jid.is_some());
                let group = match group_jid {
                    Some(group) => caller_group(client, group, &call.from).await,
                    None => None,
                };
                let chat = match group {
                    Some(group) => group,
                    None => lids::phone_chat(inbox, client, &call.from).await,
                };
                self.lock().log = Some(Log {
                    id: call_id.clone(),
                    chat: chat.clone(),
                    video: *is_video,
                    outgoing: false,
                    started: now(),
                    connected: None,
                });
                if let Some(listener) = self.listener() {
                    listener.on_call_ringing(call_id.clone(), chat, *is_video);
                }
            }
            CallAction::Accept { call_id, .. } => self.mark_connected(call_id),
            // `busy` and `enc` speak for one device; the others keep ringing.
            // In a group call these speak for one participant; the call's
            // own end comes from its media.
            CallAction::Reject { call_id, .. } | CallAction::Terminate { call_id, .. }
                if self.in_group_call(call_id) => {}
            CallAction::Reject {
                call_id, reason, ..
            } if reason.is_none() => {
                if let Some(handle) = self.handle().filter(|h| h.call_id() == call_id) {
                    handle.hangup_local().await;
                }
                self.finish(call_id, CallEnd::Declined);
            }
            CallAction::Terminate { call_id, .. } => {
                let ringing = self
                    .lock()
                    .ringing
                    .as_ref()
                    .is_some_and(|r| r.action.call_id() == call_id);
                if ringing {
                    // MissedCall or CallEndedElsewhere follows with the reason.
                    return;
                }
                if let Some(handle) = self.handle().filter(|h| h.call_id() == call_id) {
                    handle.hangup_local().await;
                }
                self.finish(call_id, CallEnd::Remote);
            }
            _ => {}
        }
    }
}

#[uniffi::export]
impl Core {
    /// Where call events go. Set once, before any call.
    pub fn set_call_listener(&self, listener: Arc<dyn CallListener>) {
        if let Ok(mut slot) = self.calls.listener.lock() {
            *slot = Some(listener);
        }
    }

    /// Calls a person, or everyone in a group, and returns the call id.
    /// Ringing ends in `on_call_connected` or `on_call_ended`.
    ///
    /// # Errors
    /// `SendRefused` for a chat that cannot be called, another call in
    /// progress, or when the call cannot be placed.
    pub async fn place_call(&self, chat_id: String, video: bool) -> Result<String, CoreError> {
        let (calls, client) = (Arc::clone(&self.calls), Arc::clone(&self.client));
        self.on_runtime(async move {
            let peer: Jid = chat_id
                .parse()
                .ok()
                .filter(|_| {
                    ["@s.whatsapp.net", "@lid", "@g.us"]
                        .iter()
                        .any(|s| chat_id.ends_with(s))
                })
                .ok_or_else(|| refused("Only people and groups can be called."))?;
            let group = chat_id.ends_with("@g.us");
            let listener = calls
                .listener()
                .ok_or_else(|| refused("Calls are not ready yet."))?;
            {
                let mut state = calls.lock();
                if Calls::busy(&state) {
                    return Err(refused("You're already in a call."));
                }
                state.starting = true;
            }
            let (mic, mic_rx, speaker) = audio_pair(Arc::clone(&listener));
            let voip = client.voip();
            let (camera, sink) = if video {
                let (tx, rx, screen) = video_pair(listener);
                (Some(tx), Some((rx, screen)))
            } else {
                (None, None)
            };
            let started = if group {
                let mut builder = voip.group_call_by_id(&peer).audio_opus(mic_rx, speaker);
                if let Some((rx, screen)) = sink {
                    builder = builder.video(rx, screen);
                }
                builder.start().await
            } else {
                let mut builder = voip.call(&peer).audio_opus(mic_rx, speaker);
                if let Some((rx, screen)) = sink {
                    builder = builder.video(rx, screen);
                }
                builder.start().await
            };
            let handle = match started {
                Ok(handle) => handle,
                Err(e) => {
                    calls.lock().starting = false;
                    log::warn!("call not placed: {e}");
                    return Err(refused("The call could not be placed."));
                }
            };
            let call_id = handle.call_id().to_owned();
            log::info!("call {call_id} placed (video: {video})");
            calls.lock().log = Some(Log {
                id: call_id.clone(),
                chat: chat_id,
                video,
                outgoing: true,
                started: now(),
                connected: None,
            });
            calls.adopt(Arc::clone(&client), handle, (mic, camera), true, group);
            let (calls, id) = (Arc::clone(&calls), call_id.clone());
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_secs(RING_SECS)).await;
                let unanswered = calls
                    .lock()
                    .active
                    .as_ref()
                    .filter(|a| a.handle.call_id() == id && !a.connected)
                    .map(|a| a.handle.clone());
                if let Some(handle) = unanswered {
                    let _ = handle.terminate().await;
                    calls.finish(&id, CallEnd::NoAnswer);
                }
            });
            Ok(call_id)
        })
        .await
    }

    /// Answers the ringing call, with the camera on if `video`.
    ///
    /// # Errors
    /// `SendRefused` when the call has already stopped ringing or cannot be
    /// connected.
    pub async fn answer_call(&self, call_id: String, video: bool) -> Result<(), CoreError> {
        let (calls, client) = (Arc::clone(&self.calls), Arc::clone(&self.client));
        self.on_runtime(async move {
            let listener = calls
                .listener()
                .ok_or_else(|| refused("Calls are not ready yet."))?;
            let call = {
                let mut state = calls.lock();
                let call = state
                    .ringing
                    .take()
                    .filter(|r| r.action.call_id() == call_id)
                    .ok_or_else(|| refused("The call has ended."))?;
                state.starting = true;
                call
            };
            let (mic, mic_rx, speaker) = audio_pair(Arc::clone(&listener));
            let voip = client.voip();
            let mut builder = voip.accept(&call).audio_opus(mic_rx, speaker);
            let mut camera = None;
            if video {
                let (tx, rx, screen) = video_pair(listener);
                builder = builder.video(rx, screen);
                camera = Some(tx);
            }
            match builder.start().await {
                Ok(handle) => {
                    log::info!("call {call_id} answered (video: {video})");
                    let group = matches!(
                        &call.action,
                        CallAction::Offer {
                            group_jid: Some(_),
                            ..
                        }
                    );
                    calls.adopt(Arc::clone(&client), handle, (mic, camera), false, group);
                    Ok(())
                }
                Err(e) => {
                    calls.lock().starting = false;
                    log::warn!("call {call_id} not answered: {e}");
                    let _ = client.voip().reject(&call).await;
                    Err(refused("The call could not be connected."))
                }
            }
        })
        .await
    }

    /// Declines the ringing call.
    pub async fn decline_call(&self, call_id: String) {
        let (calls, client) = (Arc::clone(&self.calls), Arc::clone(&self.client));
        let _ = self
            .on_runtime(async move {
                let call = calls
                    .lock()
                    .ringing
                    .clone()
                    .filter(|r| r.action.call_id() == call_id);
                if let Some(call) = call {
                    let _ = client.voip().reject(&call).await;
                    calls.finish(&call_id, CallEnd::Local);
                }
                Ok(())
            })
            .await;
    }

    /// Hangs up the current call, ringing or connected.
    pub async fn end_call(&self) {
        let calls = Arc::clone(&self.calls);
        let _ = self
            .on_runtime(async move {
                if let Some(handle) = calls.handle() {
                    let id = handle.call_id().to_owned();
                    let _ = handle.terminate().await;
                    calls.finish(&id, CallEnd::Local);
                }
                Ok(())
            })
            .await;
    }

    /// Mutes the microphone and tells the other side.
    pub async fn set_call_muted(&self, muted: bool) {
        let calls = Arc::clone(&self.calls);
        let _ = self
            .on_runtime(async move {
                if let Some(handle) = calls.handle()
                    && let Err(e) = handle.set_muted(muted).await
                {
                    log::info!("mute not announced: {e}");
                }
                Ok(())
            })
            .await;
    }

    /// Turns this side's camera on (answering the peer's ask if there is
    /// one) or off. Frames go in through `push_call_video`.
    ///
    /// # Errors
    /// `SendRefused` when there is no call or the switch is refused.
    pub async fn set_call_video(&self, on: bool) -> Result<(), CoreError> {
        let calls = Arc::clone(&self.calls);
        self.on_runtime(async move {
            let listener = calls
                .listener()
                .ok_or_else(|| refused("Calls are not ready yet."))?;
            let (handle, request) = {
                let mut state = calls.lock();
                let active = state
                    .active
                    .as_mut()
                    .ok_or_else(|| refused("There is no call."))?;
                if !on {
                    active.camera = None;
                }
                (active.handle.clone(), active.video_request.take())
            };
            if !on {
                return handle
                    .stop_video()
                    .await
                    .map_err(|_| refused("The camera could not be turned off."));
            }
            let (tx, rx, screen) = video_pair(listener);
            let started = match request {
                Some(request) => handle.accept_video(request, rx, screen).await,
                None => handle.start_video(rx, screen).await,
            };
            started.map_err(|e| {
                log::info!("video not started: {e}");
                refused("Video could not be turned on.")
            })?;
            if let Some(active) = calls.lock().active.as_mut() {
                active.camera = Some(tx);
            }
            Ok(())
        })
        .await
    }

    /// Asks the other side for a fresh keyframe after a decode error.
    pub fn request_call_keyframe(&self) {
        if let Some(handle) = self.calls.handle() {
            handle.request_peer_keyframe(KeyframeUrgency::Immediate);
        }
    }

    /// 16 kHz mono microphone samples, in 960-sample (60 ms) frames.
    /// Dropped when no call is up or the engine is behind.
    pub fn push_call_audio(&self, samples: Vec<i16>) {
        let mic = self.calls.lock().active.as_ref().map(|a| a.mic.clone());
        if let Some(mic) = mic {
            let _ = mic.try_send(samples);
        }
    }

    /// One Annex-B H.264 access unit from the camera.
    pub fn push_call_video(&self, frame: Vec<u8>) {
        let camera = self
            .calls
            .lock()
            .active
            .as_ref()
            .and_then(|a| a.camera.clone());
        if let Some(camera) = camera {
            let _ = camera.try_send(frame);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn log(outgoing: bool, connected: Option<i64>) -> Log {
        Log {
            id: "c".into(),
            chat: "222@s.whatsapp.net".into(),
            video: false,
            outgoing,
            started: 0,
            connected,
        }
    }

    fn outcome(outgoing: bool, connected: Option<i64>, reason: CallEnd) -> Option<Outcome> {
        log(outgoing, connected)
            .into_call(reason)
            .map(|c| c.outcome)
    }

    #[test]
    fn ends_read_as_the_timeline_shows_them() {
        let talked = Some(now() - 30);
        assert_eq!(outcome(false, None, CallEnd::Elsewhere), None);
        assert_eq!(
            outcome(true, talked, CallEnd::Failed),
            Some(Outcome::Connected)
        );
        assert_eq!(
            outcome(false, None, CallEnd::Local),
            Some(Outcome::Declined)
        );
        assert_eq!(
            outcome(true, None, CallEnd::Declined),
            Some(Outcome::Declined)
        );
        assert_eq!(outcome(true, None, CallEnd::Local), Some(Outcome::NoAnswer));
        assert_eq!(outcome(false, None, CallEnd::Remote), Some(Outcome::Missed));
        let call = log(true, talked).into_call(CallEnd::Remote).unwrap();
        assert_eq!(call.sender, ME);
        assert!((30..32).contains(&call.secs));
    }
}
