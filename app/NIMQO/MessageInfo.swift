import NimqoCore
import SwiftUI

/// Message Info for an own message: who has read it, who has it, and when.
/// Opened from its menu; lists what their receipts said.
struct MessageInfoSheet: ViewModifier {
    @Binding var message: ChatMessage?
    let isGroup: Bool
    let load: (@MainActor (Int64) async -> [Recipient])?
    let avatars: AvatarStore?

    func body(content: Content) -> some View {
        let shown = Binding { message != nil } set: {
            if !$0 {
                message = nil
            }
        }
        content.sheet(isPresented: shown) {
            if let message, let load {
                MessageInfoView(message: message, isGroup: isGroup, load: load, avatars: avatars)
            }
        }
    }
}

private struct MessageInfoView: View {
    let message: ChatMessage
    let isGroup: Bool
    let load: @MainActor (Int64) async -> [Recipient]
    let avatars: AvatarStore?
    @State private var recipients: [Recipient]?
    @Environment(\.dismiss) private var dismiss

    private var readers: [Recipient] {
        (recipients ?? []).filter { $0.readSecs != nil }
    }

    private var waiting: [Recipient] {
        (recipients ?? []).filter { $0.readSecs == nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Form {
                if recipients == nil {
                    ProgressView().frame(maxWidth: .infinity)
                } else if recipients?.isEmpty == true {
                    fallback
                } else {
                    if !readers.isEmpty {
                        Section(message.kind == .audio ? "Read or played by" : "Read by") {
                            ForEach(readers, id: \.who) { RecipientRow(recipient: $0, read: true, avatars: avatars) }
                        }
                    }
                    if !waiting.isEmpty {
                        Section("Delivered to") {
                            ForEach(waiting, id: \.who) { RecipientRow(recipient: $0, read: false, avatars: avatars) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider().opacity(0.5)
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 460)
        .windowLook()
        .task { recipients = await load(message.seq) }
    }

    /// The message itself, as a bubble, with when it went.
    private var header: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text(MessageInfoView.preview(message))
                .lineLimit(4)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 14, style: .continuous))
            Label(sent.formatted(date: .abbreviated, time: .shortened), systemImage: "paperplane")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(20)
    }

    private var sent: Date {
        Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
    }

    /// No receipts kept for it (sent before this was kept, or none yet):
    /// what the tick says.
    private var fallback: some View {
        Section {
            Label(fallbackText, systemImage: message.delivery == .read ? "checkmark.circle.fill" : "checkmark")
                .foregroundStyle(message.delivery == .read ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
        } footer: {
            if isGroup {
                Text("Who has it shows here as their phones say so.")
            }
        }
    }

    private var fallbackText: LocalizedStringKey {
        switch message.delivery {
        case .read: "Read"
        case .delivered: "Delivered"
        case .pending: "Sending…"
        case .failed: "Not sent"
        default: "Sent, not yet delivered"
        }
    }

    nonisolated static func preview(_ message: ChatMessage) -> String {
        if let body = message.body, !body.isEmpty {
            return body
        }
        return switch message.kind {
        case .image: String(localized: "Photo")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Voice message")
        case .sticker: String(localized: "Sticker")
        case .document: String(localized: "Document")
        default: String(localized: "Message")
        }
    }
}

private struct RecipientRow: View {
    let recipient: Recipient
    /// In the "Read by" list: its read (and played) time; else delivered.
    let read: Bool
    let avatars: AvatarStore?

    private var title: String {
        recipient.name ?? "+" + (recipient.who.split(separator: "@").first.map(String.init) ?? recipient.who)
    }

    var body: some View {
        HStack(spacing: 10) {
            if let avatars {
                Avatar(chat: ChatSummary(id: recipient.who, title: title, isGroup: false, phone: nil, preview: "",
                                         lastActivity: .now, unread: 0, timer: nil, muted: false),
                       store: avatars, size: 30)
            }
            Text(title).lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if read {
                    stamp(recipient.readSecs, symbol: "checkmark.circle.fill", tint: .blue)
                    stamp(recipient.playedSecs, symbol: "play.circle.fill", tint: .blue)
                } else {
                    stamp(recipient.deliveredSecs, symbol: "checkmark.circle", tint: .secondary)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder
    private func stamp(_ secs: Int64?, symbol: String, tint: Color) -> some View {
        if let secs {
            let date = Date(timeIntervalSince1970: TimeInterval(secs))
            Label(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated,
                                 time: .shortened), systemImage: symbol)
                .foregroundStyle(tint)
                .labelStyle(.titleAndIcon)
        }
    }
}

extension CoreModel {
    /// Message Info's recipients of own message `seq` in `chat`.
    func messageInfo(_ seq: Int64, in chat: String) async -> [Recipient] {
        guard let core else { return [] }
        return await Task.detached { (try? core.messageInfo(chatId: chat, seq: seq)) ?? [] }.value
    }
}
