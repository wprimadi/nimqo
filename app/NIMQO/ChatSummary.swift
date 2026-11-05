import Foundation
import NimqoCore

/// UI model for one row in the chat list.
struct ChatSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let isGroup: Bool
    let preview: String
    let lastActivity: Date
}

extension ChatSummary {
    init(_ chat: Chat) {
        id = chat.id
        // A push name is whatever the sender typed, so it never replaces the
        // number; it is marked with "~" the way WhatsApp marks unsaved contacts.
        let pushName = chat.name.map { "~\($0)" }
        title = if chat.isGroup {
            chat.name ?? "Group"
        } else {
            switch (chat.phone, pushName) {
            case let (phone?, name?): "\(phone) \(name)"
            case let (phone?, nil): phone
            case let (nil, name?): name
            case (nil, nil): "Unknown contact"
            }
        }
        isGroup = chat.isGroup
        let text = ChatMessage.describe(kind: chat.lastKind, body: chat.lastBody)
        preview = chat.lastFromMe ? "You: \(text)" : text
        lastActivity = Date(timeIntervalSince1970: TimeInterval(chat.lastActivitySecs))
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
        case .unsupported: "Message not supported yet"
        }
        guard let body, !body.isEmpty else { return label }
        return label.isEmpty || kind == .document ? body : "\(label): \(body)"
    }
}
