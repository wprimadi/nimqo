import SwiftUI

/// What the focused window lets the Chat menu turn on.
extension FocusedValues {
    @Entry var findMessages: Binding<Bool>?
    @Entry var attachFile: Binding<Bool>?
}

/// The Chat menu: keyboard shortcuts, listed where they can be found.
struct ChatCommands: Commands {
    let model: CoreModel
    @FocusedValue(\.findMessages) private var findMessages
    @FocusedValue(\.attachFile) private var attachFile

    var body: some Commands {
        CommandMenu("Chat") {
            Button("Search Messages") { findMessages?.wrappedValue = true }
                .keyboardShortcut("f")
                .disabled(findMessages == nil)
            Button("Attach a Photo or File…") { attachFile?.wrappedValue = true }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(attachFile == nil)
            Divider()
            Button("Next Chat") { model.selectChat(after: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(model.chats.isEmpty)
            Button("Previous Chat") { model.selectChat(after: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(model.chats.isEmpty)
        }
    }
}

extension CoreModel {
    /// The chat `offset` places away in the list, wrapping around.
    func selectChat(after offset: Int) {
        if let next = Self.chat(after: offset, from: selectedChat, in: chats.map(\.id)) {
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
