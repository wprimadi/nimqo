import AVFoundation
import Observation
import os
import SwiftUI
import VideoToolbox

/// The camera during a call, encoded as WhatsApp expects: H.264
/// Constrained Baseline at about 15 fps, as Annex-B access units with the
/// parameter sets in front of every keyframe.
final class CallCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "app.nimqo.call-camera")
    private let lock = NSLock()
    private var encoder: VTCompressionSession?
    private var send: (@Sendable (Data) -> Void)?
    private var wantsKeyframe = true
    private var last = CMTime.invalid
    private let log = Logger(subsystem: "app.nimqo", category: "call-camera")

    /// Starts capturing; `send` gets each encoded access unit. Blocks while
    /// the camera starts, so call it off the main thread.
    func start(send: @escaping @Sendable (Data) -> Void) throws {
        stop()
        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else {
            session.commitConfiguration()
            throw CocoaError(.featureUnsupported)
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        lock.withLock {
            self.send = send
            wantsKeyframe = true
            last = .invalid
        }
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
        let encoder = lock.withLock {
            defer {
                self.encoder = nil
                send = nil
            }
            return self.encoder
        }
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
        }
    }

    /// The other side lost the picture; the next frame starts a new one.
    func forceKeyframe() {
        lock.withLock { wantsKeyframe = true }
    }

    func captureOutput(_: AVCaptureOutput, didOutput sample: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sample)
        let (encoder, send, keyframe) = lock.withLock {
            // About 15 frames a second, whatever the camera gives.
            if last.isValid, (time - last).seconds < 1 / 16 {
                return (nil as VTCompressionSession?, nil as (@Sendable (Data) -> Void)?, false)
            }
            last = time
            if self.encoder == nil {
                self.encoder = Self.encoder(width: Int32(CVPixelBufferGetWidth(image)),
                                            height: Int32(CVPixelBufferGetHeight(image)))
            }
            defer { wantsKeyframe = false }
            return (self.encoder, self.send, wantsKeyframe)
        }
        guard let encoder, let send else { return }
        let options = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(encoder, imageBuffer: image, presentationTimeStamp: time,
                                        duration: .invalid, frameProperties: options,
                                        infoFlagsOut: nil, outputHandler: { status, _, encoded in
                                            guard status == noErr, let encoded,
                                                  let unit = Self.annexB(encoded) else { return }
                                            send(unit)
                                        })
    }

    private static func encoder(width: Int32, height: Int32) -> VTCompressionSession? {
        var made: VTCompressionSession?
        VTCompressionSessionCreate(allocator: nil, width: width, height: height,
                                   codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                                   imageBufferAttributes: nil, compressedDataAllocator: nil,
                                   outputCallback: nil, refcon: nil, compressionSessionOut: &made)
        guard let made else { return nil }
        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: 600_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 15,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 30,
        ]
        for (key, value) in settings {
            VTSessionSetProperty(made, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(made)
        return made
    }

    /// An encoded frame as one Annex-B access unit.
    private static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count,
                                         destination: &bytes) == kCMBlockBufferNoErr
        else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let keyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var units = keyframe ? parameterSets(of: sample) : []
        units += H264.units(avcc: bytes)
        return H264.annexB(units)
    }

    private static func parameterSets(of sample: CMSampleBuffer) -> [Data] {
        guard let format = CMSampleBufferGetFormatDescription(sample) else { return [] }
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil
        )
        return (0 ..< count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            )
            guard status == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
    }
}

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
/// decodes in order, and after a decoder failure only from the next intra
/// picture, so frames until then are dropped and one is asked for.
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
    private var arrived: Date?
    private let log = Logger(subsystem: "app.nimqo", category: "call-video")

    init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    func decode(_ frame: Data, orientation: UInt8) {
        queue.async { self.enqueue(frame, turns: Int(orientation & 3)) }
    }

    func reset() {
        queue.async {
            self.renderer.flush(removingDisplayedImage: true, completionHandler: nil)
            self.format = nil
            self.sps = nil
            self.pps = nil
            self.waiting = .now
            self.dropped = 0
            self.arrived = nil
            self.reported = nil
        }
    }

    private func enqueue(_ frame: Data, turns: Int) {
        // A freeze with no decoder failure is the network, not this side.
        if let arrived, Date.now.timeIntervalSince(arrived) > 1 {
            log.info("no video frames for \(Date.now.timeIntervalSince(arrived), format: .fixed(precision: 1)) s")
        }
        arrived = .now
        let slices = slices(of: frame)
        // Parameter sets alone: they come just before the picture.
        guard !slices.isEmpty else { return }
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            let error = renderer.error.map { String(describing: $0) } ?? "none"
            log.error("video decoder failed: \(error, privacy: .public)")
            renderer.flush()
            waiting = waiting ?? .now
        }
        let pictures = slices.filter { [1, 5].contains(H264.type(of: $0)) }
        let intra = !pictures.isEmpty && pictures.allSatisfy(H264.isIntra)
        guard waiting == nil || intra, let format,
              let sample = Self.sample(H264.avcc(slices), format: format)
        else {
            dropped += 1
            return ask()
        }
        renderer.enqueue(sample)
        if let waiting {
            let (seconds, count) = (Date.now.timeIntervalSince(waiting), dropped)
            log.info("picture after \(seconds, format: .fixed(precision: 1)) s, \(count) frames dropped")
        }
        waiting = nil
        dropped = 0
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

/// Hosts a Core Animation layer (the remote picture or the self view).
struct LayerView: NSViewRepresentable {
    let layer: CALayer

    func makeNSView(context _: Context) -> NSView {
        let view = HostView()
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_: NSView, context _: Context) {
        // The layer is fixed for the view's life; HostView keeps it sized.
    }

    private final class HostView: NSView {
        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
        }
    }
}
