import NimqoCore
import QuickLook
import SwiftUI

/// Pairing and status until the core connects, then the main window.
struct RootView: View {
    let model: CoreModel
    @Environment(Panels.self) private var panels

    var body: some View {
        Group {
            if !model.hasAcceptedDisclosure {
                OnboardingView(model: model)
            } else if model.failure == nil, model.isSessionUp {
                MainView(model: model)
            } else {
                PairingView(model: model)
            }
        }
        .sheet(item: Bindable(panels).shown) {
            PanelSheet(panel: $0, core: model.core, online: model.state == .connected, avatars: model.avatars)
        }
        .confirmationDialog("Log out and remove all data?", isPresented: Bindable(model).confirmingReset) {
            Button("Log Out and Remove Data", role: .destructive) { model.logOutAndReset() }
        } message: {
            Text("This unlinks this Mac from WhatsApp and permanently deletes the messages, media, and keys " +
                "stored here. Your phone keeps its chats.")
        }
    }
}

struct MainView: View {
    let model: CoreModel
    @State private var query = ""
    @FocusState private var searching: Bool
    @State private var findRequested = false
    @State private var section = SidebarPane.chats
    @State private var composing: NewChatView.Start?
    /// A chat opened from New Chat that has no messages yet.
    @State private var draft: ChatSummary?
    /// The list shows archived chats instead of the others.
    @State private var showingArchived = false
    @State private var starred = false
    /// Starred messages of one chat only, when opened from its card.
    @State private var starredChat: String?
    /// A message on its way to the chat picker, with the chat it is in.
    @State private var forwarding: (message: ChatMessage, chat: String)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The selected chat, or the one just started from New Chat.
    private var openChat: ChatSummary? {
        model.chats.first { $0.id == model.selectedChat } ?? draft.flatMap { $0.id == model.selectedChat ? $0 : nil }
    }

    var body: some View {
        NavigationSplitView {
            Group {
                if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResults(model: model, query: query)
                } else {
                    switch section {
                    case .chats: chatList
                    case .status: statusList
                    case .channels: ChannelList(store: model.channels, avatars: model.avatars)
                    case .communities: CommunityList(store: model.communities, avatars: model.avatars)
                    }
                }
            }
            // Room under the bar, so the top row's selection does not touch it.
            .safeAreaInset(edge: .top, spacing: Theme.Spacing.small) {
                PaneBar(section: $section, chatsUnread: model.chats.contains { $0.unread > 0 && !$0.quiet },
                        composing: $composing, starred: $starred, enabled: model.core != nil)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search messages")
            .searchFocus($searching)
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: 320)
        } detail: {
            if section == .channels {
                ChannelDetail(store: model.channels, pictures: model.pictures)
            } else if section == .communities {
                communityDetail
            } else if section == .status {
                statusDetail
            } else if let chat = openChat {
                if model.messagesChat != chat.id {
                    // Never show another chat's messages while this one loads.
                    ProgressView()
                } else {
                    conversation(chat)
                }
            } else {
                ContentUnavailableView(
                    "Select a chat",
                    systemImage: "bubble.left.and.text.bubble.right",
                    description: Text("Pick a conversation on the left. ⌘1 to ⌘9 open the most recent ones.")
                )
            }
        }
        // The status viewer covers the whole window, toolbar included.
        .overlay {
            if let update = model.statuses.playing {
                StatusPlayer(update: update, store: model.statuses, pictures: model.pictures, avatars: model.avatars)
                    .id(update.seq)
            }
        }
        .toolbar(model.statuses.playing == nil ? .automatic : .hidden, for: .windowToolbar)
        .quickLookPreview(Bindable(model.pictures).previewing)
        .environment(\.openChat, OpenChatAction { chat in
            section = .chats
            draft = model.chats.contains { $0.id == chat.id } ? nil : chat
            model.selectedChat = chat.id
        })
        .sheet(item: $composing) { start in
            NewChatView(core: model.core, avatars: model.avatars, start: start) { chat in
                query = ""
                section = .chats
                draft = model.chats.contains { $0.id == chat.id } ? nil : chat
                model.selectedChat = chat.id
            }
        }
        .sheet(isPresented: $starred, onDismiss: { starredChat = nil }, content: {
            StarredView(model: model, chat: starredChat)
        })
        .sheet(isPresented: forwardingShown) {
            if let forwarding {
                let targets = model.chats.filter { model.canSend($0.id) }
                ForwardPicker(message: forwarding.message, chats: targets, avatars: model.avatars) { picked in
                    await model.forward(forwarding.message.seq, from: forwarding.chat, to: picked)
                }
            }
        }
        .focusedSceneValue(\.findMessages, $findRequested)
        .focusedSceneValue(\.composing, model.core == nil ? nil : $composing)
        .focusedSceneValue(\.showStarred, model.core == nil ? nil : $starred)
        .onChange(of: findRequested) {
            guard findRequested else { return }
            findRequested = false
            searching = true
        }
    }

    /// Typed here, not in the ternary: there the closure got no type and
    /// was converted to a sendable one, which Swift warns about.
    private func sender(to id: String) -> @MainActor (String, Int64?) async -> String? {
        { [model] text, reply in await model.send(text, replyTo: reply, to: id) }
    }

    private func conversation(_ chat: ChatSummary) -> some View {
        ConversationView(
            chat: chat,
            messages: model.messages,
            hasOlder: model.hasOlderMessages,
            isFetchingOlder: model.isFetchingOlder,
            pictures: model.pictures,
            loadOlder: { await model.loadOlderMessages() },
            // Bound to this chat: a send still running after
            // switching chats goes where it was started.
            send: model.canSend(chat.id)
                ? sender(to: chat.id) : nil,
            sendFile: { await model.sendFile($0, caption: $1, to: chat.id) },
            reveal: model.revealing,
            revealed: { model.revealing = nil },
            retry: { model.retry($0, in: chat.id) },
            react: { seq, emoji in Task { await model.react(emoji, to: seq, in: chat.id) } },
            show: { seq in Task { await model.reveal(seq, in: chat.id) } },
            commands: MessageCommands(
                star: { seq, starred in Task { await model.setStarred(seq, in: chat.id, starred) } },
                edit: { seq, text in await model.edit(seq, in: chat.id, to: text) },
                delete: { seq in Task { await model.deleteForEveryone(seq, in: chat.id) } },
                deleteForMe: { seq in Task { await model.deleteForMe(seq, in: chat.id) } },
                forward: { forwarding = ($0, chat.id) },
                isAdmin: { [contacts = model.contacts] in contacts.isAdmin(of: chat.id) },
                sendVoice: { await model.sendVoice($0, to: chat.id) },
                stickers: model.core.map { core in
                    StickerPicking(core: core) { await model.sendSticker($0, gif: $1, to: chat.id) }
                },
                info: { await model.messageInfo($0, in: chat.id, waiting: $1) },
                avatars: model.avatars,
                sendPoll: { await model.sendPoll($0, options: $1, multiple: $2, to: chat.id) }
            )
        )
        // A new view per chat: it opens at the latest message.
        .id(chat.id)
        .chatHeader(chat: chat, model: model) {
            starredChat = chat.id
            starred = true
        }
    }

    private var communityDetail: some View {
        CommunityDetail(store: model.communities, avatars: model.avatars) { chat in
            // A group joined but quiet so far has no row in Chats yet.
            section = .chats
            draft = model.chats.contains { $0.id == chat.id } ? nil : chat
            model.selectedChat = chat.id
        }
    }

    /// Nothing is playing: write a new update.
    private var statusDetail: some View {
        StatusComposer(core: model.core)
    }

    private var statusList: some View {
        let store = model.statuses
        return List(store.posters, selection: Bindable(store).selected) { poster in
            StatusRow(poster: poster, avatars: model.avatars)
                .listRowSeparator(.visible)
        }
        .onChange(of: store.selected) {
            if let id = store.selected, store.playing == nil {
                store.play(from: id)
            }
        }
        .overlay {
            if store.posters.isEmpty {
                ContentUnavailableView(
                    "No status updates",
                    systemImage: "circle.dashed",
                    description: Text("Updates from the last 24 hours appear here as they arrive.")
                )
            }
        }
    }

    private var forwardingShown: Binding<Bool> {
        Binding { forwarding != nil } set: {
            if !$0 {
                forwarding = nil
            }
        }
    }

    private var archivedCount: Int {
        model.chats.count(where: \.archived)
    }

    private var chatList: some View {
        let shown = model.chats.filter { $0.archived == showingArchived }
        return List(selection: Bindable(model).selectedChat) {
            if showingArchived || archivedCount > 0 {
                archivedRow
            }
            ForEach(shown) { chat in
                ChatRow(chat: chat, avatars: model.avatars)
                    .listRowSeparator(.visible)
                    .contextMenu { ChatListMenu(chat: chat, model: model) }
            }
        }
        // Pinning moves a chat to the top, archiving takes it away: the
        // rows slide to their new places instead of jumping.
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0), value: shown.map(\.id))
        .overlay {
            if shown.isEmpty {
                ContentUnavailableView(
                    showingArchived ? "No archived chats" : "No chats yet",
                    systemImage: showingArchived ? "archivebox" : "bubble.left.and.bubble.right",
                    description: Text(showingArchived ? "Archived chats stay here, quiet, until you unarchive them."
                        : "New messages appear here as they arrive.")
                )
            }
        }
    }

    /// "Archived" above the chats, or the way back from them.
    private var archivedRow: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.3, bounce: 0)) { showingArchived.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: showingArchived ? "chevron.backward" : "archivebox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44)
                Text(showingArchived ? "Chats" : "Archived").font(.body.weight(.semibold))
                Spacer()
                if !showingArchived {
                    Text("\(archivedCount)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showingArchived ? "Back to chats" : "Archived chats, \(archivedCount)")
    }
}

struct ChatRow: View {
    let chat: ChatSummary
    let avatars: AvatarStore

    var body: some View {
        HStack(spacing: 12) {
            Avatar(chat: chat, store: avatars, size: 44)
            details
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                // The icon keeps a group subject from passing as a person.
                if chat.isGroup {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Group")
                }
                Text(chat.title).font(.body.weight(.semibold)).lineLimit(1)
                if chat.timer != nil {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Disappearing messages")
                }
                if chat.muted {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Muted")
                }
                Spacer()
                if chat.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                Text(ChatRow.stamp(chat.lastActivity))
                    .font(.caption.monospacedDigit())
                    // Tinted while there is something to read, like WhatsApp.
                    .foregroundStyle(chat.unread > 0 && !chat.quiet ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            HStack {
                Group {
                    if let activity = chat.activity {
                        TypingLabel(text: activity, recording: chat.recording)
                    } else {
                        Text(chat.preview).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .font(.subheadline)
                .animation(.snappy, value: chat.activity)
                if chat.unread > 0 {
                    Spacer()
                    Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chat.quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)))
                        .accessibilityLabel("\(chat.unread) unread")
                }
            }
        }
    }

    /// The time today, "Yesterday", the weekday this week, else the date.
    nonisolated static func stamp(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }
}
