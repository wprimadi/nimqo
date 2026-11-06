import SwiftUI

@main
struct NimqoApp: App {
    @State private var model = CoreModel()

    var body: some Scene {
        // One main window. Closing it keeps the app and the session running;
        // the Dock icon or the menu bar reopens it, Quit ends both (plan 7.6).
        Window("NIMQO", id: MainWindow.id) {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .task { model.start() }
        }

        .commands {
            CommandGroup(after: .appInfo) { ResetCommand(model: model) }
            ChatCommands(model: model)
        }

        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Label("NIMQO", systemImage: model.statusSymbol)
                .accessibilityValue(model.statusText)
        }
    }
}

enum MainWindow {
    static let id = "main"
}

/// App menu > Log Out. Opens the window, where the confirmation is shown.
struct ResetCommand: View {
    let model: CoreModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Log Out and Remove Data…") {
            openWindow(id: MainWindow.id)
            model.confirmingReset = true
        }
        .disabled(!model.canReset)
    }
}

/// Kept small on purpose (plan 7.5): status, open, quit. Recent chats join
/// when the core lists chats (Phase 3), Settings when a setting exists.
struct StatusMenu: View {
    let model: CoreModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Divider()
        Button("Open NIMQO") {
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
        .keyboardShortcut("o")
        Button("Quit NIMQO") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
