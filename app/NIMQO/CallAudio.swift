import AVFoundation
import os

/// The microphone and speaker during a call: 16 kHz mono 16-bit PCM both
/// ways, through the system's voice processing, so the speaker is not
/// heard back as an echo. Frames come and go on audio and Rust threads.
final class CallAudio: @unchecked Sendable {
    /// What the call engine takes per frame: 60 ms.
    static let frameSamples = 960
    /// Playback queued beyond this is dropped; late audio is worse than none.
    private static let maxQueued = 6

    // swiftlint:disable force_unwrapping
    private let wire = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1,
                                     interleaved: true)!
    private let playback = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    // swiftlint:enable force_unwrapping
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pending: [Int16] = []
    private var queued = 0
    private var muted = false
    private let log = Logger(subsystem: "app.nimqo", category: "call-audio")

    /// Starts the microphone; `send` gets each full frame.
    /// Voice processing fails to start on some audio setups (macOS builds
    /// an aggregate of the default input and output, and virtual devices
    /// can break it); the call then goes on without echo cancellation.
    func start(send: @escaping @Sendable ([Int16]) -> Void) throws {
        stop()
        do {
            try start(voiceProcessing: true, send: send)
        } catch {
            log.error("voice processing unavailable, no echo cancellation: \(error, privacy: .public)")
            try start(voiceProcessing: false, send: send)
        }
    }

    private func start(voiceProcessing: Bool, send: @escaping @Sendable ([Int16]) -> Void) throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: wire) else {
            throw CocoaError(.featureUnsupported)
        }
        converter.downmix = true
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.capture(buffer, with: converter).forEach(send)
        }
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playback)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        player.play()
        lock.withLock {
            self.engine = engine
            self.player = player
            pending = []
            queued = 0
            muted = false
        }
    }

    func stop() {
        let engine = lock.withLock {
            defer {
                self.engine = nil
                player = nil
            }
            return self.engine
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
    }

    /// Muted, the microphone sends silence, so the call keeps its timing.
    func setMuted(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    /// The other side's voice.
    func play(_ samples: [Int16]) {
        let player = lock.withLock { queued < Self.maxQueued ? self.player : nil }
        guard let player, !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: playback, frameCapacity: AVAudioFrameCount(samples.count)),
              let out = buffer.floatChannelData?[0]
        else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            out[index] = Float(sample) / 32768
        }
        lock.withLock { queued += 1 }
        player.scheduleBuffer(buffer) { [weak self] in
            self?.lock.withLock { self?.queued -= 1 }
        }
    }

    /// Converts to the wire format and cuts whole frames.
    private func capture(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> [[Int16]] {
        let ratio = wire.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: wire, frameCapacity: capacity) else { return [] }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let samples = out.int16ChannelData?[0] else {
            log.error("microphone audio not converted")
            return []
        }
        let chunk = Array(UnsafeBufferPointer(start: samples, count: Int(out.frameLength)))
        return lock.withLock {
            pending += muted ? [Int16](repeating: 0, count: chunk.count) : chunk
            var frames: [[Int16]] = []
            while pending.count >= Self.frameSamples {
                frames.append(Array(pending.prefix(Self.frameSamples)))
                pending.removeFirst(Self.frameSamples)
            }
            return frames
        }
    }
}
