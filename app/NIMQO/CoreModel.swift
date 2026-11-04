import Foundation
import NimqoCore
import Observation
import os

/// Owns the Rust core and mirrors its state for the UI. Views read this;
/// they never call the core directly.
@MainActor
@Observable
final class CoreModel {
    private(set) var status: ConnectionStatus?
    private(set) var qrPayload: String?
    private(set) var failure: String?
    /// ponytail: always empty until the core exposes `list_chats` (Phase 3).
    private(set) var chats: [ChatSummary] = []
    private var core: Core?
    private let log = Logger(subsystem: "app.nimqo", category: "core-model")

    func start() {
        // Unit tests host the app; never connect a real account from a test.
        guard core == nil, NSClassFromString("XCTestCase") == nil else { return }
        // Phase 0/1 talk to one allowlisted number only, given at launch.
        guard let peer = ProcessInfo.processInfo.environment["NIMQO_TEST_PEER"] else {
            failure = "Set NIMQO_TEST_PEER before launching."
            return
        }
        let listener = Listener(model: self)
        Task.detached {
            do {
                let core = try Core.start(testPeer: peer, listener: listener)
                await MainActor.run { self.core = core }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    func update(status: ConnectionStatus) {
        log.info("status \(String(describing: status), privacy: .public)")
        self.status = status
        if status != .waitingForScan {
            qrPayload = nil
        }
    }

    func update(qrPayload payload: String) {
        qrPayload = payload
    }

    func fail(_ error: Error) {
        log.error("start failed: \(String(describing: error), privacy: .public)")
        failure = Self.message(for: error)
    }

    static func message(for error: Error) -> String {
        switch error as? CoreError {
        case .InvalidPeer:
            "NIMQO_TEST_PEER is not an international phone number."
        case .Storage:
            "Encrypted storage could not be opened. NIMQO will not continue without it."
        case .Startup:
            "NIMQO could not start the WhatsApp connection."
        case nil:
            "Unexpected error: \(error.localizedDescription)"
        }
    }
}

/// UI model for one row in the chat list.
struct ChatSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let lastActivity: Date
    let unreadCount: Int
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
