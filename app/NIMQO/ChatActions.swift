import AppKit
import NimqoCore
import SwiftUI

extension CoreModel {
    /// The chat list as shown: archived chats sit under Archived instead.
    var listed: [ChatSummary] {
        chats.filter { !$0.archived }
    }

    func setPinned(_ chat: String, _ pinned: Bool) async {
        await run { try await $0.setPinned(chatId: chat, pinned: pinned) }
    }

    func setArchived(_ chat: String, _ archived: Bool) async {
        await run { try await $0.setArchived(chatId: chat, archived: archived) }
    }

    func setStarred(_ seq: Int64, in chat: String, _ starred: Bool) async {
        await run { try await $0.setStarred(chatId: chat, seq: seq, starred: starred) }
    }

    func deleteForEveryone(_ seq: Int64, in chat: String) async {
        await run { try await $0.deleteForEveryone(chatId: chat, seq: seq) }
    }

    /// Replaces the text of own message `seq`. Returns why it was refused.
    func edit(_ seq: Int64, in chat: String, to text: String) async -> String? {
        guard let core else { return "Not connected." }
        do {
            try await core.editMessage(chatId: chat, seq: seq, text: text)
            return nil
        } catch {
            return Self.message(for: error)
        }
    }

    /// Queues a forwarded copy of message `seq` of `chat` in each of `to`.
    /// Returns why it was refused.
    func forward(_ seq: Int64, from chat: String, to targets: [String]) async -> String? {
        guard let core else { return "Not connected." }
        let result = await Task.detached { Result { try core.forward(chatId: chat, seq: seq, to: targets) } }.value
        if case let .failure(error) = result {
            return Self.message(for: error)
        }
        return nil
    }

    func starredMessages() async -> [SearchHit] {
        guard let core else { return [] }
        return await Task.detached { (try? core.starredMessages()) ?? [] }.value
    }

    /// Changes that go to every device of the account; a refusal is shown.
    private func run(_ change: @escaping (Core) async throws -> Void) async {
        guard let core else { return }
        do {
            try await change(core)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

extension ChatMessage {
    /// Own text, still inside WhatsApp's edit window.
    var isEditable: Bool {
        fromMe && kind == .text && delivery != .pending && delivery != .failed
            && Int64(Date.now.timeIntervalSince1970) - timestampSecs < editWindowSecs()
    }

    /// Own, sent, and still inside WhatsApp's window to delete for everyone.
    var canDeleteForEveryone: Bool {
        fromMe && kind != .deleted && delivery != .pending && delivery != .failed
            && Int64(Date.now.timeIntervalSince1970) - timestampSecs < deleteWindowSecs()
    }

    /// A copy can be sent on: text, or media stored here.
    var isForwardable: Bool {
        switch kind {
        case .text: true
        case .image, .video, .audio, .document, .sticker: hasMedia
        default: false
        }
    }
}

/// Pin, archive, and mute, from a chat's context menu.
struct ChatListMenu: View {
    let chat: ChatSummary
    let model: CoreModel

    var body: some View {
        if model.canSend(chat.id) {
            Button(chat.pinned ? "Unpin" : "Pin", systemImage: chat.pinned ? "pin.slash" : "pin") {
                Task { await model.setPinned(chat.id, !chat.pinned) }
            }
            // WhatsApp keeps three chats pinned at most.
            .disabled(!chat.pinned && model.chats.count(where: \.pinned) >= 3)
            let archive = chat.archived ? "tray.and.arrow.up" : "archivebox"
            Button(chat.archived ? "Unarchive" : "Archive", systemImage: archive) {
                Task { await model.setArchived(chat.id, !chat.archived) }
            }
            Button(chat.muted ? "Unmute" : "Mute", systemImage: chat.muted ? "bell" : "bell.slash") {
                Task { await model.setMuted(chat.id, !chat.muted) }
            }
        }
    }
}
