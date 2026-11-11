import Foundation
import NimqoCore
import SwiftUI

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
    /// The disappearing-message duration in seconds; 0 when off.
    var timerSecs: UInt32 = 0
    var pinned = false
    /// Out of the chat list, under Archived; quiet like a muted chat.
    var archived = false
    /// "typing…" or "Ana is recording audio…" now; nil when quiet.
    var activity: String?
    var recording = false

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
        timerSecs = chat.timerSecs
        muted = chat.muted
        pinned = chat.pinned
        archived = chat.archived
        activity = Self.activityText(chat.activity)
        recording = chat.activity?.recording ?? false
    }
}

extension ChatMessage {
    /// Text, or a label for content the timeline cannot show yet.
    static func describe(kind: MessageKind, body: String?) -> String {
        if kind == .call {
            return CallEntry(body).text
        }
        let label = switch kind {
        case .text, .poll, .location, .contact, .buttons: ""
        case .image: "Photo"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .sticker: "Sticker"
        case .deleted: "This message was deleted"
        case .call, .unsupported: "Message not supported yet"
        }
        guard let body, !body.isEmpty else { return label }
        return label.isEmpty || kind == .document ? body : "\(label): \(body)"
    }
}

/// A call in a timeline; the core stores it as `<voice|video> <outcome> <seconds>`.
struct CallEntry {
    let video: Bool
    let outcome: String
    let secs: Int

    init(_ body: String?) {
        let parts = (body ?? "").split(separator: " ").map(String.init)
        video = parts.first == "video"
        outcome = parts.count > 1 ? parts[1] : ""
        secs = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
    }

    var missed: Bool {
        outcome == "missed"
    }

    var label: some View {
        Label { Text(text) } icon: {
            Image(systemName: symbol).foregroundStyle(missed ? .red : .secondary)
        }
    }

    var symbol: String {
        switch (video, missed) {
        case (true, _): "video.fill"
        case (false, true): "phone.arrow.down.left.fill"
        case (false, false): "phone.fill"
        }
    }

    var text: String {
        let call = video ? String(localized: "Video call") : String(localized: "Voice call")
        switch outcome {
        case "connected":
            let length = Duration.seconds(secs)
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
            return "\(call) · \(length)"
        case "missed": return video ? String(localized: "Missed video call") : String(localized: "Missed voice call")
        case "declined":
            return video ? String(localized: "Declined video call") : String(localized: "Declined voice call")
        case "noanswer": return String(localized: "\(call) · No answer")
        default: return String(localized: "\(call) · Failed")
        }
    }
}
