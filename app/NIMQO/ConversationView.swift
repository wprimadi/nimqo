import NimqoCore
import SwiftUI

/// Timeline, plus a composer where sending is allowed. Older messages load
/// a page at a time when the top is reached; plain SwiftUI until the
/// rendering spike says otherwise.
struct ConversationView: View {
    let chat: ChatSummary
    let messages: [ChatMessage]
    let hasOlder: Bool
    /// Shows the spinner; a chat that merely might have more shows none.
    let isFetchingOlder: Bool
    let pictures: PictureStore
    let loadOlder: @MainActor () async -> Void
    /// Nil makes the chat read-only. Returns why a message was refused.
    let send: (@MainActor (String, Int64?) async -> String?)?
    let sendFile: @MainActor (URL) async -> String?
    @State private var replyingTo: ChatMessage?
    /// Files dropped anywhere on the chat, handed to the composer to send.
    @State private var dropped: [URL] = []
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            timeline
            if let send {
                Divider()
                Composer(send: send, sendFile: sendFile, replyingTo: $replyingTo, dropped: $dropped)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard send != nil, !files.isEmpty else { return false }
            dropped += files
            return true
        } isTargeted: { isDropTarget = $0 && send != nil }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .navigationTitle(chat.title)
        // Like WhatsApp, the timer belongs to the chat, not to each message.
        .navigationSubtitle(chat.timer.map { "Disappearing messages: \($0)" } ?? "")
    }

    /// The topmost message on screen, reported by the scroll view as the
    /// user scrolls; paging keys off it rather than off views appearing.
    @State private var topSeq: Int64?
    @State private var isLoading = false
    /// Whether the end of the timeline is on screen; new messages follow
    /// only then, so reading older ones is never interrupted.
    @State private var atBottom = true

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.Spacing.small) {
                    if hasOlder, isFetchingOlder {
                        ProgressView().controlSize(.small)
                    }
                    // seq, not id: ids repeat across senders in groups.
                    ForEach(messages, id: \.seq) { message in
                        MessageBubble(message: message, showsSender: chat.isGroup, chat: chat.id, pictures: pictures)
                            .contextMenu {
                                if send != nil, message.kind != .deleted {
                                    Button("Reply", systemImage: "arrowshape.turn.up.left") { replyingTo = message }
                                }
                            }
                    }
                    Color.clear.frame(height: 1)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .scrollTargetLayout()
                .padding(Theme.Spacing.medium)
            }
            .scrollPosition(id: $topSeq, anchor: .top)
            .defaultScrollAnchor(.bottom)
            .onChange(of: topSeq) { _, top in
                // Near the oldest loaded message: load the page before it.
                if hasOlder, let top, messages.prefix(5).contains(where: { $0.seq == top }) {
                    showOlder()
                }
            }
            .onChange(of: messages.last?.seq) { _, last in
                // A new message: follow it if the end was in view or it is ours.
                guard let last, atBottom || messages.last?.fromMe == true else { return }
                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
            }
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

    /// One page at a time; the scroll restore above keeps a page coming in
    /// from triggering the next one by itself.
    private func showOlder() {
        guard !isLoading else { return }
        isLoading = true
        Task {
            await loadOlder()
            isLoading = false
        }
    }
}

struct Composer: View {
    let send: @MainActor (String, Int64?) async -> String?
    let sendFile: @MainActor (URL) async -> String?
    @Binding var replyingTo: ChatMessage?
    @Binding var dropped: [URL]
    @State private var text = ""
    @State private var picking = false
    @State private var refusal: String?
    @State private var isSending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if let refusal {
                Text(refusal).font(.caption).foregroundStyle(.red)
            }
            if let replyingTo {
                HStack {
                    QuoteView(reply: Reply(
                        kind: replyingTo.kind,
                        body: replyingTo.body,
                        fromMe: replyingTo.fromMe,
                        senderName: replyingTo.contactName ?? replyingTo.senderName
                    ))
                    Spacer()
                    Button("Cancel reply", systemImage: "xmark.circle.fill") { self.replyingTo = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                }
            }
            HStack(alignment: .bottom) {
                Button("Attach a photo or file", systemImage: "paperclip") { picking = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(isSending)
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
        .onChange(of: replyingTo?.seq) { focused = true }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.item]) { result in
            guard case let .success(url) = result else { return }
            sendFiles([url])
        }
        .onChange(of: dropped) {
            guard !dropped.isEmpty, !isSending else { return }
            let urls = dropped
            dropped = []
            sendFiles(urls)
        }
        .focusedSceneValue(\.attachFile, $picking)
    }

    /// One after another, stopping at the first refusal (the queue limit,
    /// for one), so its reason stays on screen.
    private func sendFiles(_ urls: [URL]) {
        refusal = nil
        isSending = true
        Task {
            for url in urls {
                // A dropped file is readable only while its access is held.
                let scoped = url.startAccessingSecurityScopedResource()
                refusal = await sendFile(url)
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
                if refusal != nil {
                    break
                }
            }
            isSending = false
            if !dropped.isEmpty {
                let more = dropped
                dropped = []
                sendFiles(more)
            }
        }
    }

    private func submit() {
        // Return on an empty field does nothing, like other chat apps.
        guard !isSending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        refusal = nil
        isSending = true
        let draft = text
        let reply = replyingTo
        Task {
            refusal = await send(draft, reply?.seq)
            // Keep the draft when it was refused, so nothing typed is lost.
            if refusal == nil, text == draft {
                text = ""
                if replyingTo?.seq == reply?.seq {
                    replyingTo = nil
                }
            }
            isSending = false
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let showsSender: Bool
    let chat: String
    let pictures: PictureStore

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
                if let reply = message.reply {
                    QuoteView(reply: reply)
                }
                if message.hasMedia {
                    switch message.kind {
                    case .video: VideoMessageView(chat: chat, message: message, store: pictures)
                    case .audio: AudioMessageView(chat: chat, message: message, store: pictures)
                    default: MessagePictureView(chat: chat, message: message, store: pictures)
                    }
                }
                // A shown picture needs no "Photo" label, only its caption.
                if !(message.hasMedia && message.body == nil) {
                    Text(text)
                        .italic(message.kind != .text && !message.hasMedia)
                        .textSelection(.enabled)
                }
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

/// The quoted message of a reply: who wrote it and what it said.
struct QuoteView: View {
    let reply: Reply

    private var name: String? {
        reply.fromMe == true ? "You" : reply.senderName
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if let name {
                    Text(name).font(.caption.bold()).foregroundStyle(.tint)
                }
                Text(ChatMessage.describe(kind: reply.kind, body: reply.body))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Reply to \(name ?? "a message"): \(ChatMessage.describe(kind: reply.kind, body: reply.body))"
        )
    }
}
