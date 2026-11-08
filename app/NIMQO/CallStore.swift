import AppKit
import AVFoundation
import NimqoCore
import Observation
import os

/// The one call there can be: ringing, answering, and the microphone and
/// camera behind it. Media goes straight between the core and the audio and
/// video objects; only call state comes through the main actor.
@MainActor
@Observable
final class CallStore {
    enum Phase: Equatable {
        case incoming, calling, connecting, connected
        case ended(CallEnd)
    }

    struct Call: Equatable {
        /// Tells two calls with the same person apart.
        let started = Date()
        var id: String?
        let chat: String
        let outgoing: Bool
        /// Placed or offered as a video call.
        let video: Bool
        var phase: Phase
        var camera = false
        var peerVideo = false
        var peerAsks = false
        var muted = false
        var connectedAt: Date?

        var isOver: Bool {
            if case .ended = phase {
                return true
            }
            return false
        }

        /// While placing, the id is not known yet.
        func matches(_ id: String) -> Bool {
            self.id == nil || self.id == id
        }
    }

    private(set) var current: Call?
    private(set) var problem: String?
    var core: Core? {
        didSet {
            if let bridge {
                core?.setCallListener(listener: bridge)
            }
        }
    }

    @ObservationIgnored let audio = CallAudio()
    @ObservationIgnored let camera = CallCamera()
    @ObservationIgnored let preview: AVCaptureVideoPreviewLayer
    let remote = RemoteVideo()
    /// A call rang while NIMQO could not answer: the chat.
    @ObservationIgnored var missed: ((String) -> Void)?
    @ObservationIgnored private var bridge: CallBridge?
    @ObservationIgnored private var ringtone: NSSound?
    private let log = Logger(subsystem: "app.nimqo", category: "calls")

    init() {
        preview = AVCaptureVideoPreviewLayer(session: camera.session)
        preview.videoGravity = .resizeAspectFill
        bridge = CallBridge(audio: audio, camera: camera, remote: remote) { [weak self] signal in
            Task { @MainActor in self?.handle(signal) }
        }
        remote.onLoss = { [weak self] in self?.core?.requestCallKeyframe() }
    }

    func place(_ chat: String, video: Bool) {
        guard current == nil, let core else { return }
        problem = nil
        let call = Call(chat: chat, outgoing: true, video: video, phase: .calling)
        current = call
        Task {
            let camera = await startMedia(video: video)
            // Hung up while the microphone was being asked for.
            guard isLive(call) else { return stopMedia() }
            guard let camera else { return finish(.failed) }
            current?.camera = camera
            do {
                let id = try await core.placeCall(chatId: chat, video: camera)
                // Hung up while it was being placed.
                guard isLive(call) else {
                    await core.endCall()
                    return stopMedia()
                }
                current?.id = id
            } catch {
                problem = CoreModel.message(for: error)
                finish(.failed)
            }
        }
    }

    func answer(video: Bool) {
        guard var call = current, call.phase == .incoming, let id = call.id, let core else { return }
        ring(false)
        problem = nil
        call.phase = .connecting
        current = call
        Task {
            let camera = await startMedia(video: video)
            // The caller gave up while the microphone was being asked for.
            guard isLive(call) else { return stopMedia() }
            guard let camera else {
                await core.declineCall(callId: id)
                return finish(.failed)
            }
            current?.camera = camera
            do {
                try await core.answerCall(callId: id, video: camera)
                // Hung up while it was connecting: the core had no call to end yet.
                if !isLive(call) {
                    await core.endCall()
                    stopMedia()
                }
            } catch {
                problem = CoreModel.message(for: error)
                finish(.failed)
            }
        }
    }

    func decline() {
        guard let call = current, call.phase == .incoming, let id = call.id else { return }
        ring(false)
        Task {
            await core?.declineCall(callId: id)
            finish(.local)
        }
    }

    /// Hangs up whatever state the call is in.
    func hangUp() {
        guard let call = current, !call.isOver else { return }
        if call.phase == .incoming {
            return decline()
        }
        Task {
            await core?.endCall()
            finish(.local)
        }
    }

    func toggleMute() {
        guard var call = current, !call.isOver else { return }
        call.muted.toggle()
        current = call
        audio.setMuted(call.muted)
        let muted = call.muted
        Task { await core?.setCallMuted(muted: muted) }
    }

    /// Turns this side's camera on or off; on also answers the other side's
    /// ask for video.
    func toggleCamera() {
        guard let call = current, !call.isOver, call.phase != .incoming else { return }
        if call.camera {
            current?.camera = false
            stopCamera()
            Task { try? await core?.setCallVideo(on: false) }
            return
        }
        Task {
            guard await startCamera() else { return }
            current?.camera = true
            current?.peerAsks = false
            do {
                try await core?.setCallVideo(on: true)
            } catch {
                problem = CoreModel.message(for: error)
                current?.camera = false
                stopCamera()
            }
        }
    }

    /// The ask for video goes unanswered; it times out on its own.
    func ignoreVideoAsk() {
        current?.peerAsks = false
    }

    private func handle(_ signal: CallBridge.Signal) {
        switch signal {
        case let .ringing(id, chat, video):
            guard current?.isOver ?? true else { return }
            problem = nil
            current = Call(id: id, chat: chat, outgoing: false, video: video, phase: .incoming)
            ring(true)
            NSApp.requestUserAttention(.criticalRequest)
        case let .connected(id):
            guard current?.matches(id) == true, current?.isOver == false else { return }
            current?.phase = .connected
            current?.connectedAt = .now
        case let .ended(id, reason):
            if current?.matches(id) == true {
                finish(reason)
            }
        case let .missed(chat):
            missed?(chat)
        case let .peerVideo(id, state):
            if current?.matches(id) == true {
                peerVideo(state)
            }
        }
    }

    private func peerVideo(_ state: PeerVideo) {
        current?.peerAsks = state == .requested
        if state != .requested {
            current?.peerVideo = state == .on
        }
        if state == .off {
            remote.reset()
        }
    }

    /// The microphone, then the camera if asked; nil without a microphone,
    /// otherwise whether the camera is on.
    private func startMedia(video: Bool) async -> Bool? {
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = String(localized: """
            NIMQO needs the microphone for calls. Allow it in System Settings › Privacy & Security › Microphone.
            """)
            return nil
        }
        do {
            try audio.start { [core] samples in core?.pushCallAudio(samples: samples) }
        } catch {
            log.error("microphone not started: \(error, privacy: .public)")
            problem = String(localized: "The microphone could not be started.")
            return nil
        }
        return video ? await startCamera() : false
    }

    private func startCamera() async -> Bool {
        guard await AVCaptureDevice.requestAccess(for: .video) else {
            problem = String(localized: """
            NIMQO needs the camera for video. Allow it in System Settings › Privacy & Security › Camera.
            """)
            return false
        }
        let (camera, core) = (camera, core)
        do {
            try await Task.detached { try camera.start { core?.pushCallVideo(frame: $0) } }.value
            return true
        } catch {
            problem = String(localized: "The camera could not be started.")
            return false
        }
    }

    /// Still the call that `call` started, and not over.
    private func isLive(_ call: Call) -> Bool {
        current?.started == call.started && current?.isOver == false
    }

    /// Never leaves the microphone or camera on after a call is gone.
    private func stopMedia() {
        audio.stop()
        stopCamera()
    }

    private func stopCamera() {
        let camera = camera
        Task.detached { camera.stop() }
    }

    private func finish(_ reason: CallEnd) {
        guard let call = current, !call.isOver else { return }
        ring(false)
        stopMedia()
        remote.reset()
        current?.phase = .ended(reason)
        log.info("call ended: \(String(describing: reason))")
        // Long enough to read why, then the window goes.
        Task {
            try? await Task.sleep(for: .seconds(problem == nil ? 1.6 : 4))
            if current?.started == call.started {
                current = nil
            }
        }
    }

    private func ring(_ ringing: Bool) {
        if ringing {
            ringtone = ringtone ?? NSSound(named: "Submarine")
            ringtone?.loops = true
            ringtone?.play()
        } else {
            ringtone?.stop()
        }
    }
}

/// Receives the core's call callbacks on Rust threads. Media goes straight
/// to the audio and video objects; the rest hops to the store.
final class CallBridge: CallListener {
    enum Signal: Sendable {
        case ringing(String, String, Bool)
        case connected(String)
        case ended(String, CallEnd)
        case missed(String)
        case peerVideo(String, PeerVideo)
    }

    private let audio: CallAudio
    private let camera: CallCamera
    private let remote: RemoteVideo
    private let signal: @Sendable (Signal) -> Void

    init(audio: CallAudio, camera: CallCamera, remote: RemoteVideo, signal: @escaping @Sendable (Signal) -> Void) {
        self.audio = audio
        self.camera = camera
        self.remote = remote
        self.signal = signal
    }

    func onCallRinging(callId: String, chatId: String, video: Bool) {
        signal(.ringing(callId, chatId, video))
    }

    func onCallConnected(callId: String) {
        signal(.connected(callId))
    }

    func onCallEnded(callId: String, reason: CallEnd) {
        signal(.ended(callId, reason))
    }

    func onMissedCall(chatId: String) {
        signal(.missed(chatId))
    }

    func onPeerVideo(callId: String, state: PeerVideo) {
        signal(.peerVideo(callId, state))
    }

    func onCallAudio(samples: [Int16]) {
        audio.play(samples)
    }

    func onCallVideo(frame: Data, keyframe _: Bool, orientation: UInt8) {
        remote.show(frame, orientation: orientation)
    }

    func onKeyframeNeeded() {
        camera.forceKeyframe()
    }
}
