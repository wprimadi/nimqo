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
    let revealed: @MainActor () -> Void
    /// Sends a failed message (seq) again.
    let retry: @MainActor (Int64) -> Void
    /// Reacts to a message (seq); an empty emoji removes the reaction.
    let react: @MainActor (Int64, String) -> Void
    /// Scrolls to a message (seq), loading older pages if needed.
    let show: @MainActor (Int64) -> Void
    /// Star, edit, delete, and forward.
    let commands: MessageCommands
    @State private var marked: Int64?
    @State private var pulsing: Int64?
    /// The message the full emoji list is open for.
    @State var pickingEmoji: Int64?
    @State var emojiRequests = 0
    @State var replyingTo: ChatMessage?
    @State var editing: ChatMessage?
    /// Waiting for the user to confirm deleting it for everyone.
    @State var deleting: ChatMessage?
    /// Its Message Info is open.
    @State var infoFor: ChatMessage?
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
                                 lastEditable: messages.last { $0.isEditable }, sendVoice: commands.sendVoice,
                                 stickers: commands.stickers, sendPoll: commands.sendPoll,
                                 members: commands.members, avatars: commands.avatars)
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
            .modifier(DeleteConfirmation(deleting: $deleting, commands: commands, isGroup: chat.isGroup))
            .modifier(MessageInfoSheet(message: $infoFor, isGroup: chat.isGroup, load: commands.info,
                                       avatars: commands.avatars))
            .navigationTitle(chat.title)
    }

    /// Near the oldest loaded message (macOS 14 only, see `TimelinePaging`).
    @State private var nearTop = false
    @State private var isLoading = false
    /// Whether the end of the timeline is on screen; new messages follow
    /// only then, so reading older ones is never interrupted.
    @State private var atBottom = true
    /// Bumped by the jump button to scroll to the latest message.
    @State private var scrollToEnd = 0
    /// Computed once per change of messages, not per row: scrolling
    /// re-renders rows, and a pass over every message each time stutters.
    @State private var breaks = Breaks()
    /// Which rows are drawn in full; the rest are stand-ins.
    @State private var window = TimelineWindow()

    private var timeline: some View {
        ScrollViewReader { proxy in
            let live = window.live(messages.map(\.seq))
            ScrollView {
                TimelineStack {
                    if hasOlder, isFetchingOlder {
                        ProgressView().controlSize(.small)
                    }
                    // seq, not id: ids repeat across senders in groups.
                    ForEach(messages, id: \.seq) { message in
                        TimelineRow(standIn: window.standIn(message.seq, live: live)) {
                            window.measured(message.seq, height: $0)
                        } content: {
                            row(message)
                        }
                    }
                    if let activity = chat.activity {
                        TypingBubble(text: activity, recording: chat.recording)
                    }
                    Color.clear.frame(height: 1)
                        .onShownChange { atBottom = $0 }
                }
                .scrollTargetLayout()
                .legacyScrollGeometry { visible, height in
                    window.scrolled(to: visible)
                    atBottom = visible.maxY > height - 40
                    if nearTop != (visible.minY < 600) {
                        nearTop.toggle()
                        if nearTop, hasOlder {
                            showOlder()
                        }
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .timelineWindow($window)
            // Near the oldest loaded message: load the page before it.
            .modifier(TimelinePaging {
                if hasOlder {
                    showOlder()
                }
            })
            .bottomAnchored()
            // Full size even when the content is narrow: it sized to a short
            // description, and the bar above with it.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: messages, initial: true) { old, new in
                breaks = Breaks(new)
                // Rows whose message changed are measured again.
                let before = Dictionary(old.map { ($0.seq, $0) }, uniquingKeysWith: { $1 })
                window.forget(new.filter { message in before[message.seq].map { $0 != message } ?? false }
                    .map(\.seq))
            }
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

    /// A message with the date above it when it starts a day.
    @ViewBuilder
    private func row(_ message: ChatMessage) -> some View {
        if breaks.days.contains(message.seq) {
            DayChip(date: Date(timeIntervalSince1970: TimeInterval(message.timestampSecs)))
        }
        MessageBubble(message: message, showsSender: chat.isGroup, chat: chat.id, pictures: pictures,
                      openQuote: show, actions: actions(for: message))
            // Only rows whose message changed are drawn
            // again: in a busy group every arrival redrew all.
            .equatable()
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
