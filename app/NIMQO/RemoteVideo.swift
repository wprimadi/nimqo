import AVFoundation
import Observation
import os

/// The other side's camera: what the call window shows. Decoding happens
/// in `RemoteDecoder`, off the main thread.
@MainActor
@Observable
final class RemoteVideo {
    @ObservationIgnored let layer = AVSampleBufferDisplayLayer()
    /// Quarter turns the picture needs, counterclockwise, to stand upright.
    private(set) var turns = 0
    private(set) var hasPicture = false
    /// Asks the other side for a fresh keyframe.
    @ObservationIgnored var onLoss: (() -> Void)?
    @ObservationIgnored private let decoder: RemoteDecoder

    init() {
        layer.videoGravity = .resizeAspectFill
        decoder = RemoteDecoder(renderer: layer.sampleBufferRenderer)
        decoder.shown = { [weak self] turns in Task { @MainActor in self?.shown(turns) } }
        decoder.lost = { [weak self] in Task { @MainActor in self?.onLoss?() } }
    }

    nonisolated func show(_ frame: Data, orientation: UInt8) {
        decoder.decode(frame, orientation: orientation)
    }

    func reset() {
        decoder.reset()
        hasPicture = false
        turns = 0
    }

    private func shown(_ turns: Int) {
        hasPicture = true
        self.turns = turns
    }
}

/// Feeds the layer's renderer on one queue, in arrival order: H.264 only
/// decodes in order. A frame that fails to decode asks the peer for a
/// keyframe while the stream goes on (stopping until an IDR froze the
/// picture: peers rarely send one). Only a renderer that has to be flushed
/// waits for the next IDR, since nothing else decodes after a flush. (A
/// plain I picture is not enough: resuming on one left the picture black.)
final class RemoteDecoder: @unchecked Sendable {
    /// Set once, before the first frame.
    var shown: (@Sendable (Int) -> Void)?
    var lost: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "app.nimqo.remote-video")
    private let renderer: AVSampleBufferVideoRenderer
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var reported: Int?
    private var asked = Date.distantPast
    /// Since when frames are dropped while waiting for an intra picture.
    private var waiting: Date? = .now
    private var dropped = 0
    /// Plain I pictures dropped while waiting: tells whether the peer answers
    /// keyframe requests with them rather than an IDR.
    private var intraDropped = 0
    private var arrived: Date?
    /// Frames the renderer could not decode this call, and the last reason.
    private var failures = 0
    private var failure: String?
    private var observer: Any?
    private let log = Logger(subsystem: "app.nimqo", category: "call-video")

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
        observer = NotificationCenter.default.addObserver(
            forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: renderer, queue: nil
        ) { [weak self] note in
            let error = note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey]
            let text = error.map { String(describing: $0) } ?? "unknown"
            guard let self else { return }
            queue.async {
                self.failures += 1
                self.failure = text
                self.ask()
            }
        }
    }

    func decode(_ frame: Data, orientation: UInt8) {
        queue.async { self.enqueue(frame, turns: Int(orientation & 3)) }
    }

    func reset() {
        queue.async {
            if self.failures > 0 {
                let (count, last) = (self.failures, self.failure ?? "")
                self.log.notice("\(count) video frames failed to decode, last: \(last, privacy: .public)")
            }
            self.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            self.format = nil
            self.sps = nil
            self.pps = nil
            self.waiting = .now
            self.dropped = 0
            self.intraDropped = 0
            self.failures = 0
            self.failure = nil
            self.arrived = nil
            self.reported = nil
        }
    }

    private func enqueue(_ frame: Data, turns: Int) {
        // A freeze with no decoder failure is the network, not this side.
        if let arrived, Date.now.timeIntervalSince(arrived) > 1 {
            log.notice("no video frames for \(Date.now.timeIntervalSince(arrived), format: .fixed(precision: 1)) s")
        }
        arrived = .now
        let slices = slices(of: frame)
        // Parameter sets alone: they come just before the picture.
        guard !slices.isEmpty else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let error = renderer.error.map { String(describing: $0) } ?? "none"
            log.error("video renderer needs a flush: \(error, privacy: .public)")
            renderer.flush()
            waiting = waiting ?? .now
        }
        let idr = slices.contains { H264.type(of: $0) == 5 }
        guard waiting == nil || idr, let format,
              let sample = Self.sample(H264.avcc(slices), format: format)
        else {
            dropped += 1
            let pictures = slices.filter { H264.type(of: $0) == 1 }
            if !pictures.isEmpty, pictures.allSatisfy(H264.isIntra) {
                intraDropped += 1
            }
            return ask()
        }
        renderer.enqueue(sample)
        if let waiting {
            let (seconds, count, intra) = (Date.now.timeIntervalSince(waiting), dropped, intraDropped)
            log.notice("""
            picture after \(seconds, format: .fixed(precision: 1)) s, \(count) frames dropped, \(intra) of them I
            """)
        }
        waiting = nil
        dropped = 0
        intraDropped = 0
        if reported != turns {
            reported = turns
            shown?(turns)
        }
    }

    /// The frame's slices; its parameter sets update the format.
    private func slices(of frame: Data) -> [Data] {
        var slices: [Data] = []
        for unit in H264.units(annexB: frame) {
            switch H264.type(of: unit) {
            case 7 where unit != sps:
                sps = unit
                format = nil
            case 8 where unit != pps:
                pps = unit
                format = nil
            case 7, 8: break
            default: slices.append(unit)
            }
        }
        if format == nil, let sps, let pps {
            format = Self.format(sps: sps, pps: pps)
        }
        return slices
    }

    /// At most once a second; the call engine paces it further.
    private func ask() {
        guard Date.now.timeIntervalSince(asked) > 1 else { return }
        asked = .now
        lost?()
    }

    private static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress
                else { return nil }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                var format: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &format
                )
                return format
            }
        }
    }

    private static func sample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count,
                                           blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                           dataLength: data.count, flags: 0, blockBufferOut: &block)
        guard let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            bytes.baseAddress.map {
                CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: block, offsetIntoDestination: 0,
                                              dataLength: data.count)
            }
        }
        guard copied == kCMBlockBufferNoErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                  sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
                                  sampleSizeArray: &size, sampleBufferOut: &sample)
        guard let sample else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
