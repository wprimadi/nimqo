import Foundation
import NimqoCore

/// UI model for one row in the chat list.
struct ChatSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let isGroup: Bool
    /// `+<digits>` for a person's chat.
    let phone: String?
    let preview: String
    let lastActivity: Date
    let unread: Int
    /// Disappearing-message duration, e.g. "1 day"; nil when off.
    let timer: String?
    /// Muted on one of the account's devices: no notification, no count.
    let muted: Bool
    var pinned = false
    /// Out of the chat list, under Archived; quiet like a muted chat.
    var archived = false

    /// No notification and no count on the Dock.
    var quiet: Bool {
        muted || archived
    }
}

extension ChatSummary {
    init(_ chat: Chat) {
        id = chat.id
        // A push name is whatever the sender typed, so it never replaces the
        // number; it is marked with "~" the way WhatsApp marks unsaved contacts.
        let pushName = chat.name.map { "~\($0)" }
        title = if chat.isGroup {
            chat.name ?? "Group"
        } else if let saved = chat.contactName {
            // The user's own address book: trusted, shown as is.
            saved
        } else {
            switch (chat.phone, pushName) {
            case let (phone?, name?): "\(phone) \(name)"
            case let (phone?, nil): phone
            case let (nil, name?): name
            case (nil, nil): "Unknown contact"
            }
        }
        isGroup = chat.isGroup
        phone = chat.phone
        let text = ChatMessage.describe(kind: chat.lastKind, body: chat.lastBody)
        preview = chat.lastFromMe ? "You: \(text)" : text
        lastActivity = Date(timeIntervalSince1970: TimeInterval(chat.lastActivitySecs))
        unread = Int(chat.unread)
        timer = chat.timerSecs == 0 ? nil : CoreModel.duration(UInt64(chat.timerSecs))
        muted = chat.muted
        pinned = chat.pinned
        archived = chat.archived
    }
}

extension ChatMessage {
    /// Text, or a label for content the timeline cannot show yet.
    static func describe(kind: MessageKind, body: String?) -> String {
        let label = switch kind {
        case .text: ""
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .sticker: "Sticker"
        case .deleted: "This message was deleted"
        case .unsupported: "Message not supported yet"
        }
        guard let body, !body.isEmpty else { return label }
        return label.isEmpty || kind == .document ? body : "\(label): \(body)"
    }
}
