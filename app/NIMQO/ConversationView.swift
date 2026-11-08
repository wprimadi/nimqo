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
    /// Scrolls to a message (seq), loading older pages if needed.
    var show: @MainActor (Int64) -> Void = { _ in }
    /// Star, edit, delete, and forward.
    var commands = MessageCommands()
    @State private var marked: Int64?
    @State private var pulsing: Int64?
    /// The message the full emoji list is open for.
    @State var pickingEmoji: Int64?
    @State var emojiRequests = 0
    @State var replyingTo: ChatMessage?
    @State var editing: ChatMessage?
    /// Waiting for the user to confirm deleting it for everyone.
    @State var deleting: ChatMessage?
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
                        Composer(send: send, sendFile: sendFile, replyingTo: $replyingTo, dropped: $dropped,
                                 editing: $editing, edit: commands.edit,
                                 lastEditable: messages.last { $0.isEditable })
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
            .overlay {
                if let open = lightbox.message {
                    LightboxView(lightbox: lightbox, message: open, chat: chat.id, store: pictures)
                        .transition(.opacity)
                }
            }
            .environment(lightbox)
            .modifier(DeleteConfirmation(deleting: $deleting, delete: commands.delete))
            .navigationTitle(chat.title)
    }

    /// The topmost message on screen, reported by the scroll view as the
    /// user scrolls (macOS 14 only, see `TimelinePaging`).
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
                TimelineStack {
                    if hasOlder, isFetchingOlder {
                        ProgressView().controlSize(.small)
                    }
                    // seq, not id: ids repeat across senders in groups.
                    ForEach(messages, id: \.seq) { message in
                        if breaks.days.contains(message.seq) {
                            DayChip(date: Date(timeIntervalSince1970: TimeInterval(message.timestampSecs)))
                        }
                        MessageBubble(message: message, showsSender: chat.isGroup, chat: chat.id, pictures: pictures,
                                      openQuote: show, actions: actions(for: message))
                            // A shown message pops once, on a band across the
                            // whole row that fades away, like on the phone.
                            .scaleEffect(pulsing == message.seq ? 1.06 : 1,
                                         anchor: message.fromMe ? .trailing : .leading)
                            .background {
                                if marked == message.seq {
                                    Rectangle().fill(.tint.opacity(0.25))
                                        .padding(.horizontal, -Theme.Spacing.medium)
                                        .padding(.vertical, -4)
                                        .transition(.opacity)
                                }
                            }
                            // Messages in a row from one sender sit close together.
                            .padding(.top, breaks.runs.contains(message.seq) ? Theme.Spacing.small : 0)
                            .contextMenu { menu(for: message) }
                    }
                    Color.clear.frame(height: 1)
                        .onShownChange { atBottom = $0 }
                }
                .scrollTargetLayout()
                .padding(Theme.Spacing.medium)
            }
            .modifier(TimelinePaging(topSeq: $topSeq) { top in
                // Near the oldest loaded message: load the page before it.
                if hasOlder, top.map({ top in messages.prefix(5).contains { $0.seq == top } }) ?? true {
                    showOlder()
                }
            })
            .bottomAnchored()
            // Full size even when the content is narrow: it sized to a short
            // description, and the bar above with it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                withAnimation(motion) { proxy.scrollTo(reveal, anchor: .center) }
                // Cleared only at the end: clearing it changes this task's id,
                // which cancels the task and skips every wait below.
                defer { revealed() }
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 350))
                withAnimation(.easeOut(duration: 0.15)) { marked = reveal }
                if !reduceMotion {
                    withAnimation(.spring(duration: 0.25, bounce: 0.5)) { pulsing = reveal }
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation(.spring(duration: 0.35, bounce: 0.4)) { pulsing = nil }
                }
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeOut(duration: 0.8)) { marked = nil }
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
    /// Jumps to the quoted message of a reply.
    var openQuote: ((Int64) -> Void)?
    /// Buttons shown on hover; none for read-only posts.
    var actions: MessageActions?
    @State var hovering = false

    private var text: String {
        message.kind == .deleted && message.fromMe
            ? String(localized: "You deleted this message")
            : ChatMessage.describe(kind: message.kind, body: message.body)
    }

    /// Mentions by name, links clickable.
    private var rich: AttributedString {
        MessageText.attributed(text, mentions: message.mentions)
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
            if message.starred {
                Image(systemName: "star.fill").accessibilityLabel("Starred")
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
                hoverBar
            }
            VStack(alignment: .leading, spacing: isVisual ? 4 : 2) {
                Group {
                    if showsSender, !message.fromMe {
                        Text(sender).font(.caption.bold()).foregroundStyle(.tint)
                    }
                    if message.forwarded {
                        Label("Forwarded", systemImage: "arrowshape.turn.up.right")
                            .font(.caption.italic())
                            .foregroundStyle(.secondary)
                    }
                    if let reply = message.reply {
                        if let seq = reply.seq, let openQuote {
                            Button { openQuote(seq) } label: { QuoteView(reply: reply) }
                                .buttonStyle(.plain)
                                .contentShape(.rect)
                                .help("Show the original message")
                        } else {
                            QuoteView(reply: reply)
                        }
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
                    Text(rich)
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
                hoverBar
                Spacer(minLength: Theme.Spacing.large)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(sender), \(String(rich.characters)), \(time.formatted(date: .omitted, time: .shortened))"
                + (message.forwarded ? ", forwarded" : "")
                + (message.edited ? ", edited" : "")
                + (message.starred ? ", starred" : "")
                + (message.reactions.map { ", reactions \($0)" } ?? "")
                + (deliverySymbol.map { ", \($0.label)" } ?? "")
        )
        .accessibilityAction(named: "Show the original message") {
            if let seq = message.reply?.seq {
                openQuote?(seq)
            }
        }
    }
}
