import NimqoCore
import SwiftUI

/// Pairing and status until the core connects, then the main window.
struct RootView: View {
    let model: CoreModel

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
    @State private var section = Pane.chats

    private enum Pane {
        case chats, status, channels
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
                    case .channels: channelList
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $section) {
                    Text("Chats").tag(Pane.chats)
                    Text("Status").tag(Pane.status)
                    Text("Channels").tag(Pane.channels)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Theme.Spacing.medium)
                .padding(.vertical, Theme.Spacing.small)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search messages")
            .searchFocus($searching)
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: 320)
        } detail: {
            if section == .channels {
                channelDetail
            } else if section == .status {
                statusDetail
            } else if let chat = model.chats.first(where: { $0.id == model.selectedChat }) {
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
        .focusedSceneValue(\.findMessages, $findRequested)
        .onChange(of: findRequested) {
            guard findRequested else { return }
            findRequested = false
            searching = true
        }
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
                ? { await model.send($0, replyTo: $1, to: chat.id) } : nil,
            sendFile: { await model.sendFile($0, caption: $1, to: chat.id) },
            reveal: model.revealing,
            revealed: { model.revealing = nil },
            retry: { model.retry($0, in: chat.id) },
            react: { seq, emoji in Task { await model.react(emoji, to: seq, in: chat.id) } }
        )
        // A new view per chat: it opens at the latest message.
        .id(chat.id)
        .chatHeader(chat: chat, avatars: model.avatars, contacts: model.contacts)
    }

    @ViewBuilder
    private var channelDetail: some View {
        let store = model.channels
        if let id = store.selected, let channel = store.channels?.first(where: { $0.id == id }) {
            ChannelView(channel: channel, store: store, pictures: model.pictures)
                .id(id)
        } else {
            ContentUnavailableView(
                "Select a channel",
                systemImage: "megaphone",
                description: Text("Posts are read from WhatsApp when a channel opens; nothing is sent back.")
            )
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

    private var channelList: some View {
        let store = model.channels
        return List(store.channels ?? [], id: \.id, selection: Bindable(store).selected) { channel in
            ChannelRow(channel: channel, avatars: model.avatars)
                .listRowSeparator(.visible)
        }
        .overlay {
            if store.channels == nil {
                if store.failed {
                    ContentUnavailableView("Couldn't load channels", systemImage: "wifi.slash")
                } else {
                    ProgressView()
                }
            } else if store.channels?.isEmpty == true {
                ContentUnavailableView(
                    "No channels",
                    systemImage: "megaphone",
                    description: Text("Channels this account follows appear here.")
                )
            }
        }
        .task { await store.load() }
    }

    private var chatList: some View {
        List(model.chats, selection: Bindable(model).selectedChat) { chat in
            ChatRow(chat: chat, avatars: model.avatars)
                .listRowSeparator(.visible)
                .contextMenu {
                    if model.canSend(chat.id) {
                        Button(chat.muted ? "Unmute" : "Mute") {
                            Task { await model.setMuted(chat.id, !chat.muted) }
                        }
                    }
                }
        }
        .overlay {
            if model.chats.isEmpty {
                ContentUnavailableView(
                    "No chats yet",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("New messages appear here as they arrive.")
                )
            }
        }
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
                Text(ChatRow.stamp(chat.lastActivity))
                    .font(.caption.monospacedDigit())
                    // Tinted while there is something to read, like WhatsApp.
                    .foregroundStyle(chat.unread > 0 && !chat.muted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            HStack {
                Text(chat.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                if chat.unread > 0 {
                    Spacer()
                    Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(chat.muted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint)))
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
