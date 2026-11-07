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
    let sendFile: @MainActor (URL, String?) async -> String?
    /// A message to scroll to and mark (from search); `revealed` clears it.
    var reveal: Int64?
    var revealed: @MainActor () -> Void = {}
    /// Sends a failed message (seq) again.
    var retry: @MainActor (Int64) -> Void = { _ in }
    /// Reacts to a message (seq); an empty emoji removes the reaction.
    var react: @MainActor (Int64, String) -> Void = { _, _ in }
    @State private var marked: Int64?
    @State private var replyingTo: ChatMessage?
    /// Files dropped anywhere on the chat, handed to the composer to send.
    @State private var dropped: [URL] = []
    @State private var isDropTarget = false
    @State private var lightbox = Lightbox()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Nil under Reduce Motion: scrolls jump and marks appear at once.
    private var motion: Animation? {
        reduceMotion ? nil : .default
    }

    var body: some View {
        // The timeline runs under the floating controls.
        timeline
            .bottomBar {
                VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                    if !atBottom {
                        Button("Jump to the latest message", systemImage: "chevron.down") { scrollToEnd += 1 }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                            .glassButton()
                            .controlSize(.extraLarge)
                            .keyboardShortcut(.downArrow, modifiers: .command)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                    if let send {
                        Composer(send: send, sendFile: sendFile, replyingTo: $replyingTo, dropped: $dropped)
                    }
                }
                .padding([.horizontal, .bottom], Theme.Spacing.medium)
                .animation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0), value: atBottom)
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
            .coordinateSpace(.named(Lightbox.space))
            .overlay {
                if let open = lightbox.message {
                    LightboxView(lightbox: lightbox, message: open, chat: chat.id, store: pictures)
                        .transition(.opacity)
                }
            }
            .environment(lightbox)
            .navigationTitle(chat.title)
    }

    /// The topmost message on screen, reported by the scroll view as the
    /// user scrolls; paging keys off it rather than off views appearing.
    @State private var topSeq: Int64?
    @State private var isLoading = false
    /// Whether the end of the timeline is on screen; new messages follow
    /// only then, so reading older ones is never interrupted.
    @State private var atBottom = true
    /// Bumped by the jump button to scroll to the latest message.
    @State private var scrollToEnd = 0
    /// Computed once per change of messages, not per row: scrolling
    /// re-renders rows, and a pass over every message each time stutters.
    @State private var breaks = Breaks()

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if hasOlder, isFetchingOlder {
                        ProgressView().controlSize(.small)
                    }
                    // seq, not id: ids repeat across senders in groups.
                    ForEach(messages, id: \.seq) { message in
                        if breaks.days.contains(message.seq) {
                            DayChip(date: Date(timeIntervalSince1970: TimeInterval(message.timestampSecs)))
                        }
                        MessageBubble(message: message, showsSender: chat.isGroup, chat: chat.id, pictures: pictures)
                            .background(
                                .tint.opacity(marked == message.seq ? 0.2 : 0),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            // Messages in a row from one sender sit close together.
                            .padding(.top, breaks.runs.contains(message.seq) ? Theme.Spacing.small : 0)
                            .contextMenu {
                                if send != nil, message.kind != .deleted {
                                    Button("Reply", systemImage: "arrowshape.turn.up.left") { replyingTo = message }
                                    ReactMenu(mine: message.myReaction) { react(message.seq, $0) }
                                }
                                if send != nil, message.delivery == .failed {
                                    Button("Try Again", systemImage: "arrow.clockwise") { retry(message.seq) }
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
            .onChange(of: messages, initial: true) { breaks = Breaks(messages) }
            .onChange(of: scrollToEnd) {
                if let last = messages.last?.seq {
                    withAnimation(motion) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .onChange(of: messages.last?.seq) { _, last in
                // A new message: follow it if the end was in view or it is ours.
                guard let last, atBottom || messages.last?.fromMe == true else { return }
                withAnimation(motion) { proxy.scrollTo(last, anchor: .bottom) }
            }
            .task(id: [reveal, messages.first?.seq]) {
                guard let reveal, messages.contains(where: { $0.seq == reveal }) else { return }
                // After the scroll kept by a page coming in above.
                try? await Task.sleep(for: .milliseconds(150))
                proxy.scrollTo(reveal, anchor: .center)
                withAnimation(motion) { marked = reveal }
                revealed()
                try? await Task.sleep(for: .seconds(2))
                withAnimation(motion) { marked = nil }
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

struct MessageBubble: View {
    let message: ChatMessage
    let showsSender: Bool
    let chat: String
    let pictures: PictureStore

    private var text: String {
        ChatMessage.describe(kind: message.kind, body: message.body)
    }

    private var sender: String {
        message.displaySender
    }

    /// A photo or video fills its bubble edge to edge, nearly.
    private var isVisual: Bool {
        message.hasMedia && (message.kind == .image || message.kind == .video)
    }

    /// With no caption, the time sits on the picture, as on the phone.
    private var timeOnPicture: Bool {
        isVisual && message.body == nil
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

    /// A sticker stands on its own, like in WhatsApp: no bubble.
    private var bubbleStyle: AnyShapeStyle {
        if message.kind == .sticker, message.hasMedia {
            AnyShapeStyle(.clear)
        } else if message.fromMe {
            AnyShapeStyle(.tint.opacity(0.2))
        } else {
            AnyShapeStyle(.quaternary)
        }
    }

    private var time: Date {
        Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
    }

    private var stamp: some View {
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
    }

    /// The time on a dark chip over the picture's corner.
    @ViewBuilder
    private var pictureStamp: some View {
        if timeOnPicture {
            stamp
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.45), in: .capsule)
                .padding(6)
                .allowsHitTesting(false)
        }
    }

    var body: some View {
        HStack {
            if message.fromMe {
                Spacer(minLength: Theme.Spacing.large)
            }
            VStack(alignment: .leading, spacing: isVisual ? 4 : 2) {
                Group {
                    if showsSender, !message.fromMe {
                        Text(sender).font(.caption.bold()).foregroundStyle(.tint)
                    }
                    if let reply = message.reply {
                        QuoteView(reply: reply)
                    }
                }
                .padding(.horizontal, isVisual ? 8 : 0)
                .padding(.top, isVisual ? 4 : 0)
                if message.hasMedia {
                    switch message.kind {
                    case .video: VideoMessageView(chat: chat, message: message, store: pictures)
                        .overlay(alignment: .bottomTrailing) { pictureStamp }
                    case .audio: AudioMessageView(chat: chat, message: message, store: pictures)
                    case .document: DocumentMessageView(chat: chat, message: message, store: pictures)
                    case .image: MessagePictureView(chat: chat, message: message, store: pictures)
                        .overlay(alignment: .bottomTrailing) { pictureStamp }
                    default: MessagePictureView(chat: chat, message: message, store: pictures)
                    }
                }
                // A shown picture needs no "Photo" label, only its caption;
                // a document shows its own name.
                if !(message.hasMedia && (message.body == nil || message.kind == .document)) {
                    Text(text)
                        .italic(message.kind != .text && !message.hasMedia)
                        .textSelection(.enabled)
                        .padding(.horizontal, isVisual ? 8 : 0)
                }
                if !timeOnPicture {
                    stamp
                        .foregroundStyle(.secondary)
                        .padding([.horizontal, .bottom], isVisual ? 8 : 0)
                }
            }
            .padding(.horizontal, isVisual ? 4 : Theme.Spacing.medium)
            .padding(.vertical, isVisual ? 4 : Theme.Spacing.small)
            .background(bubbleStyle, in: .rect(cornerRadius: isVisual ? 16 : 12, style: .continuous))
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
