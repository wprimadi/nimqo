import AVFoundation
import Observation

/// Records a voice note: the microphone, made 16 kHz mono 16-bit, in
/// memory only; the core encodes it. The levels draw the live waveform.
@MainActor
@Observable
final class VoiceRecorder {
    enum State: Equatable {
        case idle, recording, denied, failed
    }

    private(set) var state = State.idle
    /// The latest loudness, 0 to 1, newest last.
    private(set) var levels: [Float] = []
    private(set) var elapsed: TimeInterval = 0
    static let rate = 16000.0
    /// WhatsApp's own recorder stops at 15 minutes.
    static let limit: TimeInterval = 15 * 60
    static let bars = 48

    /// One tap's worth, converted.
    private struct Chunk {
        let pcm: Data
        let samples: Int
        let level: Float
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var pcm = Data()
    @ObservationIgnored private var samples = 0

    func start() async {
        guard state != .recording else { return }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            state = .denied
            return
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Self.rate,
                                         channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: format, to: target)
        else {
            state = .failed
            return
        }
        pcm = Data()
        samples = 0
        levels = []
        elapsed = 0
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let chunk = Self.convert(buffer, with: converter, to: target) else { return }
            Task { @MainActor in self?.take(chunk) }
        }
        do {
            try engine.start()
            self.engine = engine
            state = .recording
        } catch {
            input.removeTap(onBus: 0)
            state = .failed
        }
    }

    /// The recording so far, little-endian PCM, and stops.
    func finish() -> Data? {
        stopEngine()
        let data = pcm
        pcm = Data()
        // Under half a second is a slip of the hand, as in WhatsApp.
        return samples >= Int(Self.rate / 2) ? data : nil
    }

    func cancel() {
        stopEngine()
        pcm = Data()
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        if state == .recording {
            state = .idle
        }
    }

    private func take(_ chunk: Chunk) {
        guard state == .recording else { return }
        pcm.append(chunk.pcm)
        samples += chunk.samples
        elapsed = Double(samples) / Self.rate
        levels.append(chunk.level)
        if levels.count > Self.bars {
            levels.removeFirst(levels.count - Self.bars)
        }
    }

    /// The tap's buffer at 16 kHz mono, its sample count, and its peak.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to target: AVAudioFormat
    ) -> Chunk? {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var fed = false
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
        guard error == nil, let ints = out.int16ChannelData?[0] else { return nil }
        let count = Int(out.frameLength)
        let samples = UnsafeBufferPointer(start: ints, count: count)
        let peak = samples.reduce(0) { max($0, abs(Int32($1))) }
        // Speech sits low: a square root lifts the quiet parts into view.
        let level = sqrt(Float(peak) / Float(Int16.max))
        return Chunk(pcm: Data(buffer: samples), samples: count, level: level)
    }
}
