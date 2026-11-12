import AppKit
import NimqoCore

/// Pairing's clock: when the shown QR code lapses, and what waits on a
/// fresh session.
struct PairingClock {
    /// When the shown QR code stops being valid, and how long it had.
    var expires: Date?
    var lifetime: TimeInterval = 0
    /// The shown QR code lapsed and no other came after it.
    var expired = false
    /// When this session's first QR code came.
    var since: Date?
    /// A number to ask a code for once the fresh session is up.
    var pendingPhone: String?
    /// Waiting for WhatsApp to send the code asked for.
    var awaitingCode = false
    /// Refreshes made on their own since the user was last here.
    var autoRefreshes = 0
    /// A new session is on its way.
    var restarting = false
    var lapse: Task<Void, Never>?
    var answer: Task<Void, Never>?
}

extension CoreModel {
    /// A session hands out six QR codes, each replacing the last as it
    /// lapses; after the last WhatsApp ends the session.
    func update(qrPayload payload: String, timeout: UInt64) {
        if pairing.since == nil {
            pairing.since = .now
        }
        qrPayload = payload
        pairing.expired = false
        pairing.restarting = false
        pairing.lifetime = TimeInterval(timeout)
        pairing.expires = .now + TimeInterval(timeout)
        pairing.lapse?.cancel()
        pairing.lapse = Task { [weak self] in
            // The next code comes as this one lapses; a little grace.
            try? await Task.sleep(for: .seconds(Double(timeout) + 3))
            guard !Task.isCancelled, let self, state == .pairing else { return }
            pairing.expired = true
            refreshQrIfIdle()
        }
        if let phone = pairing.pendingPhone {
            pairing.pendingPhone = nil
            requestPairCode(phoneNumber: phone)
        }
    }

    /// New QR codes on their own while NIMQO is in front: a few times, then
    /// the user asks (WhatsApp Web stops at once). Never over a code being
    /// typed on the phone.
    func refreshQrIfIdle() {
        // Only while pairing: never over a linked session.
        guard state == .notPaired || (state == .pairing && pairing.expired), pairCode == nil,
              !pairing.awaitingCode,
              NSApp.isActive, pairing.autoRefreshes < 3 else { return }
        pairing.autoRefreshes += 1
        refreshPairing()
    }

    /// Linked: no QR code lapses any more, no code is waited for.
    func endPairing() {
        pairing.lapse?.cancel()
        pairing.answer?.cancel()
        pairing = PairingClock()
    }

    /// Back in front: refreshes on their own start counting again.
    func pairingResumed() {
        pairing.autoRefreshes = 0
        refreshQrIfIdle()
    }

    /// A new session, for new QR codes.
    func refreshPairing() {
        guard !pairing.restarting, !isSessionUp, core != nil else { return }
        pairing.restarting = true
        pairing.since = nil
        pairing.lapse?.cancel()
        restartCore()
    }

    func requestPairCode(phoneNumber: String) {
        pairCode = nil
        pairCodeMessage = "Requesting a code…"
        pairing.awaitingCode = true
        // A code asked for late in a session went unanswered: ask on a
        // fresh one. Before the first QR code, wait for the session.
        let late = pairing.since.map { Date.now.timeIntervalSince($0) > 50 } ?? false
        if qrPayload == nil || late {
            pairing.pendingPhone = phoneNumber
            if late || state == .notPaired || pairing.expired {
                refreshPairing()
            }
            return
        }
        do {
            try core?.requestPairCode(phoneNumber: phoneNumber)
        } catch {
            pairing.awaitingCode = false
            pairCodeMessage = Self.message(for: error)
            return
        }
        pairing.answer?.cancel()
        pairing.answer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, pairing.awaitingCode else { return }
            pairing.awaitingCode = false
            pairCodeMessage = "WhatsApp did not answer. Choose Get Code to try again."
        }
    }

    func update(pairCode code: String) {
        pairing.awaitingCode = false
        pairing.answer?.cancel()
        // Shown in two groups of four, the way WhatsApp displays it.
        pairCode = code.count == 8 ? "\(code.prefix(4))-\(code.suffix(4))" : code
        pairCodeMessage = nil
    }

    func pairCodeFailed(throttled: Bool, retryAfterSecs: UInt64?) {
        pairing.awaitingCode = false
        pairing.answer?.cancel()
        pairCode = nil
        pairCodeMessage = if throttled {
            "Too many requests. Try again in \(Self.duration(retryAfterSecs ?? 60))."
        } else {
            "WhatsApp did not issue a code. Check the number, or use the QR code."
        }
    }
}
