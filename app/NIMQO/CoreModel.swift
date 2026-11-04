import AppKit
import Network
import NimqoCore
import Observation
import os
import SwiftUI

/// Owns the Rust core and mirrors its state for the UI. Views read this;
/// they never call the core directly.
@MainActor
@Observable
final class CoreModel {
    private(set) var state: ConnectionState?
    private(set) var qrPayload: String?
    /// Code for linking by phone number, shown as `ABCD-EFGH`.
    private(set) var pairCode: String?
    private(set) var pairCodeMessage: String?
    private(set) var hasAcceptedDisclosure: Bool
    private(set) var failure: String?
    /// Bound by the confirmation dialog in `RootView`.
    var confirmingReset = false
    private(set) var isResetting = false
    /// ponytail: always empty until the core exposes `list_chats` (Phase 3).
    private(set) var chats: [ChatSummary] = []
    private var core: Core?
    private var observers = SystemObservers()
    private var lastNetworkAvailable: Bool?
    private let log = Logger(subsystem: "app.nimqo", category: "core-model")
    private let defaults: UserDefaults
    /// Bump the version when the disclosure text changes materially.
    static let disclosureKey = "disclosureAccepted.v1"

    /// The main window replaces pairing once the session has been up.
    var isSessionUp: Bool {
        switch state {
        case .connected, .reconnecting, .offline: true
        default: false
        }
    }

    var canReset: Bool {
        core != nil && !isResetting
    }

    var statusText: String {
        switch state {
        case nil, .connecting: "Connecting…"
        case .pairing: "Waiting for QR code scan"
        case .notPaired: "The QR codes expired. Quit and reopen NIMQO to try again."
        case .connected: "Connected"
        case .reconnecting: "Reconnecting…"
        case .offline: "Offline. NIMQO reconnects when the network returns."
        case .loggedOut: "Logged out. This device was unlinked."
        case .streamReplaced: "This session was opened elsewhere. Quit the other copy, then reopen NIMQO."
        case let .temporaryBan(seconds):
            "WhatsApp temporarily banned this account. Try again in \(Self.duration(seconds))."
        case .clientOutdated: "WhatsApp no longer accepts this version. Update NIMQO."
        case let .failed(reason): "Connection failed (\(reason))."
        }
    }

    var statusSymbol: String {
        switch state {
        case .connected: "checkmark.circle"
        case .pairing, .notPaired: "qrcode"
        case .offline: "wifi.slash"
        case nil, .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .loggedOut, .streamReplaced, .temporaryBan, .clientOutdated, .failed: "exclamationmark.triangle"
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAcceptedDisclosure = defaults.bool(forKey: Self.disclosureKey)
        // Quit is the only path that ends the session (plan 7.6); closing the
        // window does not. Disconnect cleanly before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Nothing connects before the user has read the disclosure (plan 21).
    func acceptDisclosure() {
        defaults.set(true, forKey: Self.disclosureKey)
        hasAcceptedDisclosure = true
        start()
    }

    func start() {
        // Unit tests host the app; never connect a real account from a test.
        guard core == nil, hasAcceptedDisclosure, NSClassFromString("XCTestCase") == nil else { return }
        // Development talks to one allowlisted number only, given at launch.
        guard let peer = ProcessInfo.processInfo.environment["NIMQO_TEST_PEER"] else {
            failure = "Set NIMQO_TEST_PEER before launching."
            return
        }
        let listener = Listener(model: self)
        Task.detached {
            do {
                let core = try Core.start(testPeer: peer, listener: listener)
                await MainActor.run { self.attach(core) }
            } catch {
                await MainActor.run { self.fail(error) }
            }
        }
    }

    /// Blocks for at most the core's shutdown grace period.
    func stop() {
        observers.stop()
        core?.stop()
        core = nil
    }

    /// Unlinks, destroys the key and local data, then pairs again. Only
    /// reached through the confirmation dialog.
    func logOutAndReset() {
        guard let core, !isResetting else { return }
        isResetting = true
        observers.stop()
        lastNetworkAvailable = nil
        Task.detached {
            let result = Result { try core.logOutAndReset() }
            await MainActor.run { self.finishReset(result) }
        }
    }

    func update(state: ConnectionState) {
        log.info("state \(String(describing: state), privacy: .public)")
        let changed = self.state != state
        self.state = state
        if changed {
            // The window may be hidden; VoiceOver users still hear the change.
            AccessibilityNotification.Announcement(statusText).post()
        }
        if state != .pairing {
            qrPayload = nil
            pairCode = nil
            pairCodeMessage = nil
        }
    }

    func update(qrPayload payload: String) {
        qrPayload = payload
    }

    func requestPairCode(phoneNumber: String) {
        pairCode = nil
        do {
            try core?.requestPairCode(phoneNumber: phoneNumber)
            pairCodeMessage = "Requesting a code…"
        } catch {
            pairCodeMessage = Self.message(for: error)
        }
    }

    func update(pairCode code: String) {
        // Shown in two groups of four, the way WhatsApp displays it.
        pairCode = code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
        pairCodeMessage = nil
    }

    func pairCodeFailed(throttled: Bool, retryAfterSecs: UInt64?) {
        pairCode = nil
        pairCodeMessage = if throttled {
            "Too many requests. Try again in \(Self.duration(retryAfterSecs ?? 60))."
        } else {
            "WhatsApp did not issue a code. Check the number, or use the QR code."
        }
    }

    func fail(_ error: Error) {
        // The detail can hold file paths; keep it out of public logs.
        log.error("start failed: \(String(describing: error), privacy: .private)")
        failure = Self.message(for: error)
    }

    static func message(for error: Error) -> String {
        switch error as? CoreError {
        case .InvalidPeer:
            "NIMQO_TEST_PEER is not an international phone number."
        case .InvalidPhoneNumber:
            "Enter the number in international format, for example +62 812 3456 7890."
        case .AlreadyRunning:
            "NIMQO is already running. Use the open copy, or quit it first."
        case .Storage:
            "Encrypted storage could not be opened. NIMQO will not continue without it."
        case .Startup:
            "NIMQO could not start the WhatsApp connection."
        case nil:
            "Unexpected error: \(error.localizedDescription)"
        }
    }

    static func duration(_ seconds: UInt64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }

    /// The monitor's first report is the starting point, not a change;
    /// reporting it would drop the connection that just came up.
    private func networkReported(_ available: Bool) {
        defer { lastNetworkAvailable = available }
        guard let last = lastNetworkAvailable, last != available else { return }
        core?.networkChanged(available: available)
    }

    private func finishReset(_ result: Result<Void, Error>) {
        isResetting = false
        core = nil
        state = nil
        qrPayload = nil
        pairCode = nil
        pairCodeMessage = nil
        switch result {
        case .success:
            failure = nil
            start()
        case let .failure(error):
            fail(error)
        }
    }

    private func attach(_ core: Core) {
        self.core = core
        observers.start(
            networkChanged: { [weak self] available in self?.networkReported(available) },
            didWake: { [weak self] in self?.core?.reconnectNow() }
        )
    }
}

/// Network, sleep/wake, and App Nap, held only while the core runs.
private struct SystemObservers {
    private var monitor: NWPathMonitor?
    private var wakeToken: NSObjectProtocol?
    private var activity: NSObjectProtocol?

    @MainActor
    mutating func start(networkChanged: @escaping @MainActor (Bool) -> Void, didWake: @escaping @MainActor () -> Void) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            MainActor.assumeIsolated { networkChanged(available) } // monitor runs on .main
        }
        monitor.start(queue: .main)
        self.monitor = monitor

        // The socket rarely survives sleep; reconnect without waiting for a timeout.
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { didWake() }
        }

        // App Nap would throttle the core's keepalive timers while the window
        // is hidden. Idle system sleep stays allowed.
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Keep the WhatsApp connection alive"
        )
    }

    mutating func stop() {
        monitor?.cancel()
        monitor = nil
        if let wakeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeToken)
        }
        wakeToken = nil
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
        }
        activity = nil
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

    func onState(state: ConnectionState) {
        Task { @MainActor [model] in model?.update(state: state) }
    }

    func onQr(code: String, timeoutSecs _: UInt64) {
        Task { @MainActor [model] in model?.update(qrPayload: code) }
    }

    func onPairCode(code: String, timeoutSecs _: UInt64) {
        Task { @MainActor [model] in model?.update(pairCode: code) }
    }

    func onPairCodeError(throttled: Bool, retryAfterSecs: UInt64?) {
        Task { @MainActor [model] in model?.pairCodeFailed(throttled: throttled, retryAfterSecs: retryAfterSecs) }
    }
}
