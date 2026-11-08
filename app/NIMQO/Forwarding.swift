import NimqoCore
import SwiftUI

/// Picks up to five chats to forward a message to, as WhatsApp allows. The
/// message shows on top, so it is clear what is being sent on.
struct ForwardPicker: View {
    let message: ChatMessage
    /// Chats a message can go to, most recent first.
    let chats: [ChatSummary]
    let avatars: AvatarStore
    /// Returns why it was refused.
    let forward: ([String]) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var picked: [String] = []
    @State private var refusal: String?
    @State private var sending = false
    @FocusState private var focused: Bool

    static let limit = 5

    private var shown: [ChatSummary] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(text) }
    }

    var body: some View {
        VStack(spacing: 0) {
            QuoteView(reply: Reply(kind: message.kind, body: message.body, fromMe: message.fromMe,
                                   senderName: message.displaySender, seq: nil))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 10, style: .continuous))
                .padding([.horizontal, .top], 14)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit {
                        if let first = shown.first, picked.isEmpty {
                            toggle(first.id)
                        }
                    }
            }
            .padding(10)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 10, style: .continuous))
            .padding([.horizontal, .top], 14)
            List(shown) { chat in
                row(chat)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .overlay {
                if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            footer
        }
        .frame(width: 420, height: 540)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        .onAppear { focused = true }
    }

    private func row(_ chat: ChatSummary) -> some View {
        let isPicked = picked.contains(chat.id)
        let full = picked.count >= Self.limit && !isPicked
        return Button { toggle(chat.id) } label: {
            HStack(spacing: 10) {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .contentTransition(.symbolEffect(.replace))
                Avatar(chat: chat, store: avatars, size: 32)
                Text(chat.title).lineLimit(1)
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(full || sending)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    private var footer: some View {
        HStack {
            if let refusal {
                Text(refusal).font(.callout).foregroundStyle(.red).lineLimit(2)
            } else {
                Text(names).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if sending {
                ProgressView().controlSize(.small)
            }
            Button("Forward", systemImage: "arrowshape.turn.up.right.fill", action: send)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty || sending)
        }
        .padding(14)
        .background(.bar)
    }

    private var names: String {
        if picked.isEmpty {
            return "Choose up to \(Self.limit) chats"
        }
        let titles = picked.compactMap { id in chats.first { $0.id == id }?.title }
        return titles.formatted(.list(type: .and))
    }

    private func toggle(_ id: String) {
        refusal = nil
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else if picked.count < Self.limit {
            picked.append(id)
        }
    }

    private func send() {
        guard !picked.isEmpty, !sending else { return }
        sending = true
        Task {
            refusal = await forward(picked)
            sending = false
            if refusal == nil {
                dismiss()
            }
        }
    }
}
