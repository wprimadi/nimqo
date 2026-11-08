import SwiftUI

/// What the focused window lets the Chat menu turn on.
extension FocusedValues {
    @Entry var findMessages: Binding<Bool>?
    @Entry var attachFile: Binding<Bool>?
    @Entry var composing: Binding<NewChatView.Start?>?
    @Entry var showStarred: Binding<Bool>?
}

/// The Chat menu: keyboard shortcuts, listed where they can be found.
struct ChatCommands: Commands {
    let model: CoreModel
    @FocusedValue(\.findMessages) private var findMessages
    @FocusedValue(\.attachFile) private var attachFile
    @FocusedValue(\.composing) private var composing
    @FocusedValue(\.showStarred) private var showStarred

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Chat") { composing?.wrappedValue = .chat }
                .keyboardShortcut("n")
                .disabled(composing == nil)
            Button("New Group") { composing?.wrappedValue = .group }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(composing == nil)
        }
        CommandMenu("Chat") {
            Button("Starred Messages") { showStarred?.wrappedValue = true }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(showStarred == nil)
            Divider()
            Button("Search Messages") { findMessages?.wrappedValue = true }
                .keyboardShortcut("f")
                .disabled(findMessages == nil)
            Button("Attach a Photo or File…") { attachFile?.wrappedValue = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(attachFile == nil)
            Divider()
            Button("Next Chat") { model.selectChat(after: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model.listed.isEmpty)
            Button("Previous Chat") { model.selectChat(after: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model.listed.isEmpty)
            Divider()
            // ⌘1 to ⌘9: the chats at the top of the list.
            ForEach(Array(model.listed.prefix(9).enumerated()), id: \.element.id) { index, chat in
                Button(chat.title) { model.selectedChat = chat.id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
        }
    }
}

extension CoreModel {
    /// The chat `offset` places away in the list, wrapping around.
    func selectChat(after offset: Int) {
        if let next = Self.chat(after: offset, from: selectedChat, in: listed.map(\.id)) {
            selectedChat = next
        }
    }

    static func chat(after offset: Int, from current: String?, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        // None selected: the first going down, the last going up.
        let start = current.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        return ids[((start + offset) % ids.count + ids.count) % ids.count]
    }
}

extension View {
    /// Focus for the search field; `searchFocused` needs macOS 15, so on 14
    /// the menu item does nothing.
    @ViewBuilder
    func searchFocus(_ focused: FocusState<Bool>.Binding) -> some View {
        if #available(macOS 15, *) {
            searchFocused(focused)
        } else {
            self
        }
    }
}

extension CoreModel {
    /// Mutes or unmutes `chat` on every device of the account.
    func setMuted(_ chat: String, _ muted: Bool) async {
        guard let core else { return }
        do {
            try await core.setMuted(chatId: chat, muted: muted)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The usual reactions; choosing the one already given takes it back.
struct ReactMenu: View {
    static let choices = ["👍", "❤️", "😂", "😮", "😢", "🙏"]
    let mine: String?
    let choose: (String) -> Void
    /// Opens the full emoji list.
    var more: (() -> Void)?

    var body: some View {
        Menu("React", systemImage: "face.smiling") {
            ForEach(Self.choices, id: \.self) { emoji in
                Button(emoji == mine ? "\(emoji) ✓" : emoji) { choose(emoji == mine ? "" : emoji) }
            }
            if mine != nil {
                Divider()
                Button("Remove Reaction") { choose("") }
            }
            if let more {
                Divider()
                Button("More Reactions…", action: more)
            }
        }
    }
}
