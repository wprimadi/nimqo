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
    private var mic: AVAudioEngine?
    private var speaker: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var pending: [Int16] = []
    private var queued = 0
    private var muted = false
    private let log = Logger(subsystem: "app.nimqo", category: "call-audio")

    /// Starts the microphone; `send` gets each full frame.
    /// Voice processing with the speaker in the same engine cancels the echo
    /// best, but on some audio setups the output side fails to start
    /// (-10875). Then voice processing goes on the microphone alone with the
    /// speaker on its own engine, and last without voice processing.
    func start(send: @escaping @Sendable ([Int16]) -> Void) throws {
        stop()
        var failure: Error = CocoaError(.featureUnsupported)
        for (voiceProcessing, together) in [(true, true), (true, false), (false, false)] {
            do {
                return try start(voiceProcessing: voiceProcessing, together: together, send: send)
            } catch {
                log.error("""
                audio start failed (voice processing \(voiceProcessing), one engine \(together)): \
                \(error, privacy: .public)
                """)
                failure = error
            }
        }
        throw failure
    }

    private func start(voiceProcessing: Bool, together: Bool, send: @escaping @Sendable ([Int16]) -> Void) throws {
        let mic = AVAudioEngine()
        let input = mic.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
        }
        let format = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: format, to: wire) else {
            throw CocoaError(.featureUnsupported)
        }
        // Voice processing reports several channels; the first is the cleaned voice.
        converter.channelMap = [0]
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.capture(buffer, with: converter).forEach(send)
        }
        let speaker = together ? mic : AVAudioEngine()
        let player = AVAudioPlayerNode()
        speaker.attach(player)
        speaker.connect(player, to: speaker.mainMixerNode, format: playback)
        do {
            try mic.start()
            if !together {
                try speaker.start()
            }
        } catch {
            input.removeTap(onBus: 0)
            mic.stop()
            speaker.stop()
            if voiceProcessing {
                try? input.setVoiceProcessingEnabled(false)
            }
            throw error
        }
        player.play()
        lock.withLock {
            self.mic = mic
            self.speaker = speaker
            self.player = player
            pending = []
            queued = 0
            muted = false
        }
    }

    func stop() {
        let (mic, speaker) = lock.withLock {
            defer {
                self.mic = nil
                self.speaker = nil
                player = nil
            }
            return (self.mic, self.speaker)
        }
        mic?.inputNode.removeTap(onBus: 0)
        mic?.stop()
        speaker?.stop()
        try? mic?.inputNode.setVoiceProcessingEnabled(false)
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
