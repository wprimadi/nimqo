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
                ChatRow(chat: chat)
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
                ConversationView(chat: chat, messages: model.messages)
            } else {
                ContentUnavailableView("Select a chat", systemImage: "text.bubble")
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatSummary

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                // The icon keeps a group subject from passing as a person.
                if chat.isGroup {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Group")
                }
                Text(chat.title).font(.headline).lineLimit(1)
                Spacer()
                Text(chat.lastActivity, format: .relative(presentation: .numeric))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(chat.preview).foregroundStyle(.secondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
