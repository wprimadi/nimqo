import Foundation
import NimqoCore

/// Receives the core's call callbacks on Rust threads. Media goes straight
/// to the audio and video objects; the rest hops to the store.
final class CallBridge: CallListener {
    enum Signal: Sendable {
        case ringing(String, String, Bool)
        case connected(String)
        case ended(String, CallEnd)
        case missed(String)
        case peerVideo(String, PeerVideo)
        case peerScreen(String, Bool)
        case participants(String, [CallParticipant])
    }

    private let audio: CallAudio
    private let camera: CallCamera
    private let remote: RemoteVideo
    private let group: GroupVideo
    private let signal: @Sendable (Signal) -> Void

    typealias Send = @Sendable (Signal) -> Void

    init(audio: CallAudio, camera: CallCamera, remote: RemoteVideo, group: GroupVideo, signal: @escaping Send) {
        self.audio = audio
        self.camera = camera
        self.remote = remote
        self.group = group
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

    func onPeerScreen(callId: String, sharing: Bool) {
        signal(.peerScreen(callId, sharing))
    }

    func onCallAudio(samples: [Int16]) {
        audio.play(samples)
    }

    func onCallVideo(frame: Data, keyframe _: Bool, orientation: UInt8, from: String?) {
        if let from, group.show(frame, orientation: orientation, from: from) {
            return
        }
        remote.show(frame, orientation: orientation)
    }

    func onCallParticipants(callId: String, participants: [CallParticipant]) {
        signal(.participants(callId, participants))
    }

    func onKeyframeNeeded() {
        camera.forceKeyframe()
    }
}
