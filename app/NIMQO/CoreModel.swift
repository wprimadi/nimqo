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
    var qrPayload: String?
    /// Code for linking by phone number, shown as `ABCD-EFGH`.
    var pairCode: String?
    var pairCodeMessage: String?
    var pairing = PairingClock()
    private(set) var hasAcceptedDisclosure: Bool
    private(set) var failure: String?
    /// Bound by the confirmation dialog in `RootView`.
    var confirmingReset = false
    private(set) var isResetting = false
    private(set) var chats: [ChatSummary] = []
    /// Timeline of `selectedChat`, oldest first; grows backwards by pages.
    private(set) var messages: [ChatMessage] = []
    /// False once neither the store nor the phone has anything older.
    private(set) var hasOlderMessages = false
    /// The oldest message (seq) the phone was asked to send history before.
    private var askedPhoneBefore: Int64?
    /// Chats whose phone history ran out this session; not asked again.
    private var historyExhausted: Set<String> = []
    /// The chat `messages` belongs to; the view waits for it to match.
    private(set) var messagesChat: String?
    private var isLoadingOlder = false
    /// Older messages are being read or awaited from the phone right now.
    var isFetchingOlder: Bool {
        isLoadingOlder || askedPhoneBefore != nil
    }

    nonisolated static let pageSize: UInt32 = 80
    /// A message (seq) of `messages` to scroll to and mark, then cleared.
    var revealing: Int64?
    var selectedChat: ChatSummary.ID? {
        didSet { loadMessages() }
    }

    /// Between `start` and the core up: a second start finds its own lock.
    private var isStarting = false
    private(set) var core: Core? {
        didSet {
            avatars.core = core
            pictures.core = core
            contacts.core = core
            channels.core = core
            communities.core = core
            statuses.core = core
            calls.core = core
            notifier.reset()
        }
    }

    let avatars = AvatarStore()
    let pictures = PictureStore()
    let contacts = ContactStore()
    let channels = ChannelStore()
    let communities = CommunityStore()
    let statuses = StatusStore()
    let calls = CallStore()
    let notifier = Notifier()
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasAcceptedDisclosure = defaults.bool(forKey: Self.disclosureKey)
        notifier.open = { [weak self] chat in self?.selectedChat = chat }
        notifier.reply = { [weak self] chat, text in await self?.send(text, replyTo: nil, to: chat) ?? nil }
        calls.missed = { [weak self] chat in
            guard let self else { return }
            notifier.missedCall(from: title(of: chat), chat: chat)
        }
        // Quit is the only path that ends the session (plan 7.6); closing the
        // window does not. Disconnect cleanly before the process exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        // Returning to the app reads the open chat.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loadMessages()
                self?.pairingResumed()
            }
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
        guard core == nil, !isStarting, hasAcceptedDisclosure, NSClassFromString("XCTestCase") == nil else { return }
        isStarting = true
        let listener = Listener(model: self)
        Task.detached {
            // A core just stopped can hold the data lock a moment longer.
            for attempt in 1 ... 10 {
                do {
                    let core = try Core.start(listener: listener)
                    await MainActor.run { self.attach(core) }
                    return
                } catch CoreError.AlreadyRunning where attempt < 10 {
                    try? await Task.sleep(for: .milliseconds(300))
                } catch {
                    await MainActor.run { self.fail(error) }
                    return
                }
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
        if state == .notPaired {
            refreshQrIfIdle()
        }
    }

    func chatsChanged(_ ids: [String]) {
        avatars.invalidate(ids)
        // Channel media is downloaded under the channel's id.
        if ids.contains(where: { $0 == StatusStore.chat || $0.hasSuffix("@newsletter") }) {
            pictures.invalidate()
            if ids.contains(StatusStore.chat) {
                statuses.load()
            }
        }
        if let selectedChat, ids.contains(selectedChat) {
            pictures.invalidate()
            contacts.invalidate()
        }
        reloadChats()
        if let selectedChat, ids.contains(selectedChat) {
            loadMessages()
            // A history answer from the phone lands before the oldest shown.
            if askedPhoneBefore != nil {
                Task { await loadOlderMessages(phoneAnswered: true) }
            }
        }
    }

    /// Reads off the main thread; the store can be busy committing.
    func reloadChats() {
        guard let core else { return }
        Task.detached {
            let result = Result { try core.chats() }
            await MainActor.run {
                switch result {
                case let .success(chats):
                    // Unchanged (a receipt, a message elsewhere): nothing
                    // to redraw, which in a busy account is most rereads.
                    let fresh = chats.map(ChatSummary.init)
                    guard fresh != self.chats else { break }
                    self.chats = fresh
                    self.notifier.update(self.chats, viewing: self.selectedChat)
                    self.expireActivity()
                case let .failure(error): self.log.error("chats: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    private func loadMessages() {
        guard let core, let id = selectedChat else {
            messages = []
            messagesChat = nil
            return
        }
        // Only what is on screen in the active app counts as read.
        let reading = NSApp?.isActive == true
        // Keep the pages already loaded for this chat.
        let limit = messagesChat == id ? max(Self.pageSize, UInt32(messages.count)) : Self.pageSize
        Task.detached {
            if reading {
                do { try core.markChatRead(chatId: id) } catch {
                    self.log.error("mark read: \(String(describing: error), privacy: .private)")
                }
            }
            let result = Result { try core.messages(chatId: id, limit: limit) }
            await MainActor.run {
                // A newer selection may have won the race.
                guard self.selectedChat == id else { return }
                switch result {
                case let .success(latest):
                    // Older pages loaded meanwhile stay: keep everything
                    // before the first message of this reload.
                    let kept = self.messagesChat == id
                        ? Self.olderThan(latest.first, in: self.messages)
                        : []
                    if kept.isEmpty {
                        // Even a short chat may have more on the phone.
                        self.hasOlderMessages = !latest.isEmpty && !self.historyExhausted.contains(id)
                        self.askedPhoneBefore = nil
                    }
                    if kept + latest != self.messages {
                        self.messages = kept + latest
                    }
                    self.messagesChat = id
                    let (count, older) = (self.messages.count, self.hasOlderMessages)
                    self.log.notice("chat loaded: \(count, privacy: .public), older: \(older, privacy: .public)")
                case let .failure(error): self.log.error("messages: \(String(describing: error), privacy: .private)")
                }
            }
        }
    }

    func fail(_ error: Error) {
        isStarting = false
        // The detail can hold file paths; keep it out of public logs.
        log.error("start failed: \(String(describing: error), privacy: .private)")
        failure = Self.message(for: error)
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
        chats = []
        selectedChat = nil
        state = nil
        qrPayload = nil
        pairCode = nil
        pairCodeMessage = nil
        pairing = PairingClock()
        switch result {
        case .success:
            failure = nil
            start()
        case let .failure(error):
            fail(error)
        }
    }

    private func attach(_ core: Core) {
        isStarting = false
        self.core = core
        reloadChats()
        observers.start(
            networkChanged: { [weak self] available in self?.networkReported(available) },
            didWake: { [weak self] in self?.core?.reconnectNow() }
        )
    }
}

/// Paging back through a chat: the store first, then the phone.
extension CoreModel {
    /// Prepends the page before the oldest loaded message; when the store
    /// has none, asks the phone, unless this is the phone's answer already.
    func loadOlderMessages(phoneAnswered: Bool = false) async {
        guard let core, let id = messagesChat, let first = messages.first,
              hasOlderMessages, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let cursor = Cursor(timestampSecs: first.timestampSecs, seq: first.seq)
        log.notice("loading an older page")
        let result = await Task.detached {
            Result { try core.olderMessages(chatId: id, before: cursor, limit: Self.pageSize) }
        }.value
        guard messagesChat == id, messages.first?.seq == first.seq else { return }
        switch result {
        case let .success(page) where page.isEmpty:
            if !phoneAnswered {
                askPhone(core: core, chat: id, before: first.seq)
            }
        case let .success(page):
            log.notice("older page: \(page.count, privacy: .public) message(s)")
            messages.insert(contentsOf: page, at: 0)
            askedPhoneBefore = nil
        case let .failure(error):
            log.error("older messages: \(String(describing: error), privacy: .private)")
        }
    }

    /// The store has nothing older: ask the phone once per oldest message,
    /// and stop if it has not answered in time (nothing older, or offline).
    private func askPhone(core: Core, chat: String, before seq: Int64) {
        guard askedPhoneBefore != seq else { return }
        askedPhoneBefore = seq
        let asked = (try? core.requestOlderHistory(chatId: chat)) ?? false
        log.notice("asked the phone for older history: \(asked, privacy: .public)")
        guard asked else { return stopPaging(chat) }
        Task {
            try? await Task.sleep(for: Self.phoneHistoryWait)
            if askedPhoneBefore == seq, messagesChat == chat {
                stopPaging(chat)
            }
        }
    }

    private func stopPaging(_ chat: String) {
        historyExhausted.insert(chat)
        askedPhoneBefore = nil
        if messagesChat == chat {
            hasOlderMessages = false
        }
    }

    /// How long the phone gets to answer a history request.
    static let phoneHistoryWait = Duration.seconds(10)
}

extension CoreModel {
    /// A person or group already here: it gets a composer, reactions, mute.
    func canSend(_ chatId: String) -> Bool {
        core?.canSend(chatId: chatId) ?? false
    }

    /// Drops the core off the main thread, then starts a new one.
    func restartCore() {
        guard let old = core else { return }
        observers.stop()
        lastNetworkAvailable = nil
        core = nil
        Task.detached {
            old.stop()
            await MainActor.run { self.start() }
        }
    }
}

extension CoreModel {
    /// The loaded messages that come before `first` in timeline order
    /// (timestamp, then storage order); none when `first` is nil.
    nonisolated static func olderThan(_ first: ChatMessage?, in loaded: [ChatMessage]) -> [ChatMessage] {
        guard let first else { return [] }
        return Array(loaded.prefix { ($0.timestampSecs, $0.seq) < (first.timestampSecs, first.seq) })
    }
}
