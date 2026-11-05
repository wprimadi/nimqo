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

    var body: some View {
        NavigationSplitView {
            List(model.chats, selection: Bindable(model).selectedChat) { chat in
                ChatRow(chat: chat, avatars: model.avatars)
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
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: 280)
        } detail: {
            if let chat = model.chats.first(where: { $0.id == model.selectedChat }) {
                if model.messagesChat != chat.id {
                    // Never show another chat's messages while this one loads.
                    ProgressView()
                } else {
                    ConversationView(
                        chat: chat,
                        messages: model.messages,
                        hasOlder: model.hasOlderMessages,
                        loadOlder: { await model.loadOlderMessages() },
                        send: chat.id == model.sendableChatId ? model.send : nil
                    )
                    // A new view per chat: it opens at the latest message.
                    .id(chat.id)
                }
            } else {
                ContentUnavailableView("Select a chat", systemImage: "text.bubble")
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatSummary
    let avatars: AvatarStore

    var body: some View {
        HStack {
            Avatar(chat: chat, store: avatars)
            details
        }
        .accessibilityElement(children: .combine)
    }

    private var details: some View {
        VStack(alignment: .leading) {
            HStack {
                // The icon keeps a group subject from passing as a person.
                if chat.isGroup {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Group")
                }
                Text(chat.title).font(.headline).lineLimit(1)
                if chat.timer != nil {
                    Image(systemName: "timer")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Disappearing messages")
                }
                Spacer()
                Text(chat.lastActivity, format: .relative(presentation: .numeric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(chat.preview).foregroundStyle(.secondary).lineLimit(1)
                if chat.unread > 0 {
                    Spacer()
                    Text(chat.unread > 99 ? "99+" : "\(chat.unread)")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(.tint))
                        .accessibilityLabel("\(chat.unread) unread")
                }
            }
        }
    }
}
