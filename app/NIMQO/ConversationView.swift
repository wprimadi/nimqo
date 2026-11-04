import NimqoCore
import SwiftUI

/// Read-only timeline. ponytail: newest 200 messages, no scrollback paging
/// yet; plain SwiftUI until the rendering spike says otherwise.
struct ConversationView: View {
    let chat: ChatSummary
    let messages: [ChatMessage]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.small) {
                ForEach(messages, id: \.id) { message in
                    MessageBubble(message: message, showsSender: chat.isGroup)
                }
            }
            .padding(Theme.Spacing.medium)
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle(chat.title)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let showsSender: Bool

    private var text: String {
        ChatMessage.describe(kind: message.kind, body: message.body)
    }

    private var sender: String {
        // ponytail: push names only until contacts are mapped; "~" marks them
        // as self-chosen.
        message.fromMe ? "You" : message.senderName.map { "~\($0)" } ?? "Unknown"
    }

    private var time: Date {
        Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
    }

    var body: some View {
        HStack {
            if message.fromMe {
                Spacer(minLength: Theme.Spacing.large)
            }
            VStack(alignment: .leading, spacing: 2) {
                if showsSender, !message.fromMe {
                    Text(sender).font(.caption.bold()).foregroundStyle(.tint)
                }
                Text(text)
                    .italic(message.kind != .text)
                    .textSelection(.enabled)
                Text(time, format: .dateTime.hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(
                message.fromMe ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                in: .rect(cornerRadius: 12)
            )
            if !message.fromMe {
                Spacer(minLength: Theme.Spacing.large)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(sender), \(text), \(time.formatted(date: .omitted, time: .shortened))")
    }
}
