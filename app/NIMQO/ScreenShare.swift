import CoreMedia
import Observation
import ScreenCaptureKit

/// A window or screen in place of the camera, picked in the system's own
/// sharing picker, which also shows macOS's sharing indicator in the menu
/// bar. Frames go through the camera's encoder, so the other side sees it
/// as the call's video.
@MainActor
@Observable
final class ScreenShare: NSObject {
    private(set) var active = false
    /// Sharing stopped from outside the call window (the menu bar).
    @ObservationIgnored var ended: (() -> Void)?
    @ObservationIgnored private var picked: ((SCContentFilter) -> Void)?
    @ObservationIgnored private var stream: SCStream?
    /// One per stream, so no picture outlives the share it came from.
    @ObservationIgnored private var output: ScreenOutput?
    /// Bumped by `stop`, so a start still under way gives up.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let camera: CallCamera

    init(camera: CallCamera) {
        self.camera = camera
    }

    func pick(_ picked: @escaping (SCContentFilter) -> Void) {
        self.picked = picked
        let picker = SCContentSharingPicker.shared
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = [.singleWindow, .singleDisplay]
        config.excludedBundleIDs = [Bundle.main.bundleIdentifier].compactMap(\.self)
        picker.defaultConfiguration = config
        picker.add(self)
        picker.isActive = true
        picker.present()
    }

    func start(_ filter: SCContentFilter) async throws {
        let generation = generation
        let output = ScreenOutput(camera: camera)
        output.stopped = { [weak self] in Task { @MainActor in self?.stoppedOutside() } }
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: filter), delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.output = output
        try await stream.startCapture()
        // Stopped (or the call ended) while capture was starting.
        guard generation == self.generation else {
            output.disable()
            try? await stream.stopCapture()
            throw CancellationError()
        }
        self.stream = stream
        active = true
    }

    /// No frame is encoded once this returns, even before capture winds down.
    func stop() {
        generation += 1
        output?.disable()
        output = nil
        let stream = stream
        self.stream = nil
        active = false
        picked = nil
        SCContentSharingPicker.shared.isActive = false
        SCContentSharingPicker.shared.remove(self)
        if let stream {
            Task { try? await stream.stopCapture() }
        }
    }

    /// Another window picked from the menu bar while sharing.
    private func update(_ filter: SCContentFilter) async {
        guard let stream else {
            picked?(filter)
            return
        }
        try? await stream.updateContentFilter(filter)
        try? await stream.updateConfiguration(Self.configuration(for: filter))
    }

    private func stoppedOutside() {
        guard active else { return }
        stop()
        ended?()
    }

    /// Full resolution up to 1280 wide, even sizes, at most 15 frames a
    /// second: what a call carries.
    private static func configuration(for filter: SCContentFilter) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        let pixels = filter.contentRect.size.applying(.init(scaleX: CGFloat(filter.pointPixelScale),
                                                            y: CGFloat(filter.pointPixelScale)))
        let fit = min(1, 1280 / max(pixels.width, 1))
        config.width = max(2, Int(pixels.width * fit) & ~1)
        config.height = max(2, Int(pixels.height * fit) & ~1)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 15)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        // One buffer stays held as the last picture.
        config.queueDepth = 5
        return config
    }
}

extension ScreenShare: SCContentSharingPickerObserver {
    nonisolated func contentSharingPicker(_: SCContentSharingPicker, didCancelFor _: SCStream?) {
        Task { @MainActor in
            if !active {
                stop()
            }
        }
    }

    nonisolated func contentSharingPicker(
        _: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for _: SCStream?
    ) {
        nonisolated(unsafe) let filter = filter
        Task { @MainActor in await update(filter) }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_: any Error) {
        Task { @MainActor in stop() }
    }
}

/// Receives the frames on its own queue.
private final class ScreenOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.nimqo.call-screen")
    /// Set once, before capture starts.
    var stopped: (@Sendable () -> Void)?
    private let camera: CallCamera
    /// Both touched only on `queue`.
    private var enabled = true
    private var last: CVPixelBuffer?

    init(camera: CallCamera) {
        self.camera = camera
    }

    /// Waits out a frame being encoded; none follows.
    func disable() {
        queue.sync {
            enabled = false
            last = nil
        }
    }

    func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, enabled else { return }
        let info = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let status = (info?.first?[.status] as? Int).flatMap(SCFrameStatus.init)
        if status == .complete, let image = sample.imageBuffer {
            last = image
        }
        // A still screen sends idle frames with no picture: the last one goes
        // again, so the stream stays alive and a keyframe asked for comes.
        guard status == .complete || status == .idle, let last else { return }
        camera.encode(last, at: sample.presentationTimeStamp)
    }

    func stream(_: SCStream, didStopWithError _: any Error) {
        stopped?()
    }
}

extension CallStore {
    var sharing: Bool {
        screen.active
    }

    /// Shares a window or screen instead of the camera, or stops sharing.
    func toggleScreen() {
        guard let call = current, call.phase == .connected else { return }
        if screen.active {
            return stopSharing()
        }
        screen.pick { [weak self] filter in
            Task { await self?.share(filter, started: call.started) }
        }
    }

    func stopSharing() {
        guard screen.active else { return }
        screen.stop()
        restoreCamera(announced: true)
    }

    private func share(_ filter: SCContentFilter, started: Date) async {
        guard current?.started == started, current?.isOver == false else { return screen.stop() }
        let (camera, core) = (camera, core)
        await Task.detached {
            camera.stop()
            camera.attach { core?.pushCallVideo(frame: $0) }
        }.value
        guard current?.started == started, current?.isOver == false else { return stopCamera() }
        do {
            try await screen.start(filter)
            // The call ended while capture was starting.
            guard current?.started == started, current?.isOver == false else {
                screen.stop()
                return stopCamera()
            }
        } catch is CancellationError {
            // Stopped while starting: by the call ending, or nothing to undo.
            if current?.started == started, current?.isOver == false {
                restoreCamera(announced: false)
            }
            return
        } catch {
            problem = String(localized: """
            The screen could not be shared. Allow NIMQO in System Settings › Privacy & Security › \
            Screen & System Audio Recording.
            """)
            screen.stop()
            return restoreCamera(announced: false)
        }
        guard current?.camera != true else { return }
        do {
            try await core?.setCallVideo(on: true)
        } catch {
            problem = CoreModel.message(for: error)
            stopSharing()
        }
    }

    /// The camera again if it was on, otherwise no video.
    private func restoreCamera(announced: Bool) {
        if current?.camera == true {
            Task { _ = await startCamera() }
            return
        }
        stopCamera()
        if announced {
            Task { try? await core?.setCallVideo(on: false) }
        }
    }
}
