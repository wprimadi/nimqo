import NimqoCore
import SwiftUI

/// Pairing and status until the core connects, then the main window.
struct RootView: View {
    let model: CoreModel

    var body: some View {
        if !model.hasAcceptedDisclosure {
            OnboardingView(model: model)
        } else if model.failure == nil, model.isSessionUp {
            MainView(chats: model.chats)
        } else {
            PairingView(model: model)
        }
    }
}

struct MainView: View {
    let chats: [ChatSummary]
    @State private var selection: ChatSummary.ID?

    var body: some View {
        NavigationSplitView {
            List(chats, selection: $selection) { chat in
                ChatRow(chat: chat)
            }
            .overlay {
                if chats.isEmpty {
                    ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
                }
            }
            .navigationSplitViewColumnWidth(min: Theme.sidebarMinWidth, ideal: 280)
        } detail: {
            if let chat = chats.first(where: { $0.id == selection }) {
                ConversationView(chat: chat)
            } else {
                ContentUnavailableView("Select a chat", systemImage: "text.bubble")
            }
        }
    }
}

struct ChatRow: View {
    let chat: ChatSummary

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(chat.title).font(.headline)
                Text(chat.preview).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if chat.unreadCount > 0 {
                Text(chat.unreadCount, format: .number)
                    .font(.caption.bold())
                    .padding(.horizontal, Theme.Spacing.small)
                    .background(.tint, in: .capsule)
                    .foregroundStyle(.white)
                    .accessibilityLabel("\(chat.unreadCount) unread")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// ponytail: shell only; the message timeline (and its rendering spike)
/// arrives with message operations in Phase 3.
struct ConversationView: View {
    let chat: ChatSummary

    var body: some View {
        ContentUnavailableView(chat.title, systemImage: "text.bubble", description: Text("Messages arrive in Phase 3."))
            .navigationTitle(chat.title)
    }
}
