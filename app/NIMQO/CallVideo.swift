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
    /// The encoder's picture size; zero when there is none.
    private var size: (Int32, Int32) = (0, 0)
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
        attach(send)
        session.startRunning()
    }

    /// Where encoded frames go, starting with a keyframe. The shared screen
    /// calls this after `stop` and feeds `encode` itself.
    func attach(_ send: @escaping @Sendable (Data) -> Void) {
        let old = lock.withLock {
            defer {
                encoder = nil
                size = (0, 0)
                self.send = send
                wantsKeyframe = true
                last = .invalid
            }
            return encoder
        }
        if let old {
            VTCompressionSessionInvalidate(old)
        }
    }

    func stop() {
        stopCapture()
        let encoder = lock.withLock {
            defer {
                self.encoder = nil
                size = (0, 0)
                send = nil
            }
            return self.encoder
        }
        if let encoder {
            VTCompressionSessionInvalidate(encoder)
        }
    }

    private func stopCapture() {
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
    }

    /// The other side lost the picture; the next frame starts a new one.
    func forceKeyframe() {
        lock.withLock { wantsKeyframe = true }
    }

    func captureOutput(_: AVCaptureOutput, didOutput sample: CMSampleBuffer, from _: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { return }
        encode(image, at: CMSampleBufferGetPresentationTimeStamp(sample))
    }

    /// One picture, at about 15 frames a second whatever the source gives.
    /// A new size (another window shared) starts a new encoder.
    func encode(_ image: CVPixelBuffer, at time: CMTime) {
        let (width, height) = (Int32(CVPixelBufferGetWidth(image)), Int32(CVPixelBufferGetHeight(image)))
        let (encoder, send, keyframe, retired) = lock.withLock {
            if last.isValid, (time - last).seconds < 1 / 16 {
                return (nil as VTCompressionSession?, nil as (@Sendable (Data) -> Void)?, false,
                        nil as VTCompressionSession?)
            }
            last = time
            var retired: VTCompressionSession?
            if size != (width, height) {
                retired = self.encoder
                self.encoder = Self.encoder(width: width, height: height)
                size = (width, height)
                wantsKeyframe = true
            }
            defer { wantsKeyframe = false }
            return (self.encoder, self.send, wantsKeyframe, retired)
        }
        if let retired {
            VTCompressionSessionInvalidate(retired)
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
            // Text on a shared screen needs more than a face does.
            kVTCompressionPropertyKey_AverageBitRate: width > 640 ? 1_500_000 : 600_000,
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
