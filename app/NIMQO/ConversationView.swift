import NimqoCore
import SwiftUI

/// Timeline, plus a composer where sending is allowed. Older messages load
/// a page at a time when the top is reached; plain SwiftUI until the
/// rendering spike says otherwise.
struct ConversationView: View {
    let chat: ChatSummary
    let messages: [ChatMessage]
    let hasOlder: Bool
    let loadOlder: @MainActor () async -> Void
    /// Nil makes the chat read-only. Returns why a message was refused.
    let send: (@MainActor (String) async -> String?)?

    var body: some View {
        VStack(spacing: 0) {
            timeline
            if let send {
                Divider()
                Composer(send: send)
            }
        }
        .navigationTitle(chat.title)
        // Like WhatsApp, the timer belongs to the chat, not to each message.
        .navigationSubtitle(chat.timer.map { "Disappearing messages: \($0)" } ?? "")
    }

    /// Whether the top of the timeline (the spinner) is on screen.
    @State private var atTop = false
    @State private var isLoading = false

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    if hasOlder {
                        ProgressView().controlSize(.small)
                            .onAppear {
                                atTop = true
                                showOlder()
                            }
                            .onDisappear { atTop = false }
                    }
                    // seq, not id: ids repeat across senders in groups.
                    ForEach(messages, id: \.seq) { message in
                        MessageBubble(message: message, showsSender: chat.isGroup)
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.first?.seq) { old, _ in
                // Older messages went in above (a page, or the phone's
                // answer): stay on the one that was first, so reading goes on
                // from there instead of jumping to the oldest.
                if let old {
                    proxy.scrollTo(old, anchor: .top)
                }
            }
        }
    }

    /// Loads one page if the top is still in view once a scroll settles, so
    /// a page coming in can never trigger the next one by itself.
    private func showOlder() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            if atTop {
                await loadOlder()
            }
            isLoading = false
        }
    }
}

struct Composer: View {
    let send: @MainActor (String) async -> String?
    @State private var text = ""
    @State private var refusal: String?
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom) {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1 ... 6)
                    .focused($focused)
                    .onSubmit(submit)
                Button("Send", systemImage: "paperplane.fill", action: submit)
                    .labelStyle(.iconOnly)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            }
        }
        .padding(Theme.Spacing.medium)
        .onAppear { focused = true }
    }

    private func submit() {
        // Return on an empty field does nothing, like other chat apps.
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refusal = nil
        isSending = true
        let draft = text
        Task {
            refusal = await send(draft)
            // Keep the draft when it was refused, so nothing typed is lost.
            if refusal == nil, text == draft {
                text = ""
            }
            isSending = false
        }
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
        message.fromMe ? "You" : message.contactName ?? message.senderName.map { "~\($0)" } ?? "Unknown"
    }

    private struct Badge {
        let name: String
        let tint: Color
        let label: String
    }

    private var deliverySymbol: Badge? {
        switch message.delivery {
        case .none: nil
        case .pending: Badge(name: "clock", tint: .secondary, label: "Sending")
        case .sent: Badge(name: "checkmark", tint: .secondary, label: "Sent")
        case .delivered: Badge(name: "checkmark.circle", tint: .secondary, label: "Delivered")
        case .read: Badge(name: "checkmark.circle.fill", tint: .blue, label: "Read")
        case .failed: Badge(name: "exclamationmark.circle.fill", tint: .red, label: "Not sent")
        }
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
                HStack(spacing: 4) {
                    Text(time, format: .dateTime.hour().minute())
                    if message.edited {
                        Text("Edited")
                    }
                    if let symbol = deliverySymbol {
                        Image(systemName: symbol.name)
                            .foregroundStyle(symbol.tint)
                            .accessibilityLabel(symbol.label)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.small)
            .background(
                message.fromMe ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.quaternary),
                in: .rect(cornerRadius: 12)
            )
            .overlay(alignment: message.fromMe ? .bottomLeading : .bottomTrailing) {
                if let reactions = message.reactions {
                    Text(reactions)
                        .font(.caption)
                        .padding(.horizontal, 4)
                        .background(.background, in: .capsule)
                        .offset(y: 10)
                }
            }
            .padding(.bottom, message.reactions == nil ? 0 : 10)
            if !message.fromMe {
                Spacer(minLength: Theme.Spacing.large)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(sender), \(text), \(time.formatted(date: .omitted, time: .shortened))"
                + (message.edited ? ", edited" : "")
                + (message.reactions.map { ", reactions \($0)" } ?? "")
                + (deliverySymbol.map { ", \($0.label)" } ?? "")
        )
    }
}
