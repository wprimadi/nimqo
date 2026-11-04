import Foundation
import NimqoCore
import Observation

/// Owns the Rust core and mirrors its state for the UI.
@MainActor
@Observable
final class CoreModel {
    private(set) var status: ConnectionStatus?
    private(set) var qrPayload: String?
    private(set) var error: String?
    private var core: Core?

    func start() {
        guard core == nil else { return }
        // Phase 0 talks to one allowlisted number only, given at launch.
        guard let peer = ProcessInfo.processInfo.environment["NIMQO_TEST_PEER"] else {
            error = "Set NIMQO_TEST_PEER before launching."
            return
        }
        let listener = Listener(model: self)
        Task.detached {
            do {
                let core = try Core.start(testPeer: peer, listener: listener)
                await MainActor.run { self.core = core }
            } catch {
                await MainActor.run {
                    print("error: \(error)")
                    self.error = error.localizedDescription
                }
            }
        }
    }

    fileprivate func update(status: ConnectionStatus) {
        print("status: \(status)")
        self.status = status
        if status != .waitingForScan {
            qrPayload = nil
        }
    }

    fileprivate func update(qrPayload payload: String) {
        qrPayload = payload
    }
}

/// Receives callbacks on Rust worker threads and hops to the main actor.
private final class Listener: CoreListener, Sendable {
    private weak let model: CoreModel?

    init(model: CoreModel) {
        self.model = model
    }

    func onStatus(status: ConnectionStatus) {
        Task { @MainActor [model] in model?.update(status: status) }
    }

    func onQr(code: String, timeoutSecs _: UInt64) {
        Task { @MainActor [model] in model?.update(qrPayload: code) }
    }
}
