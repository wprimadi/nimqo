import AppKit
import Network
import NimqoCore
import Observation
import os
import SwiftUI

/// Status and error text, derived only.
extension CoreModel {
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

    static func message(for error: Error) -> String {
        switch error as? CoreError {
        case .InvalidPhoneNumber:
            "Enter the number in international format, for example +62 812 3456 7890."
        case .AlreadyRunning:
            "NIMQO is already running. Use the open copy, or quit it first."
        case .Storage:
            "Encrypted storage could not be opened. NIMQO will not continue without it."
        case .Startup:
            "NIMQO could not start the WhatsApp connection."
        case let .SendRefused(reason):
            reason
        case nil:
            "Unexpected error: \(error.localizedDescription)"
        }
    }

    nonisolated static func duration(_ seconds: UInt64) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 2
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }
}

/// Receives callbacks on Rust worker threads and hops to the main actor.
final class Listener: CoreListener, Sendable {
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

    func onChatsChanged(chatIds: [String]) {
        Task { @MainActor [model] in model?.chatsChanged(chatIds) }
    }

    func onPairCodeError(throttled: Bool, retryAfterSecs: UInt64?) {
        Task { @MainActor [model] in model?.pairCodeFailed(throttled: throttled, retryAfterSecs: retryAfterSecs) }
    }
}
