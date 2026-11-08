import SwiftUI

@main
struct NimqoApp: App {
    @State private var model = CoreModel()
    @State private var panels = Panels()

    init() {
        // A second launch brings the running NIMQO forward instead. The
        // core's data-directory lock still guards the session if this
        // misses (another copy of the app, a race at launch).
        let others = NSRunningApplication.runningApplications(
            withBundleIdentifier: Bundle.main.bundleIdentifier ?? ""
        ).filter { $0 != .current }
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if let running = others.first, !testing {
            // macOS lets the running app come forward only if this one
            // hands over; the running app then opens its own window.
            NSApplication.shared.yieldActivation(to: running)
            DistributedNotificationCenter.default().postNotificationName(
                MainWindow.show, object: nil, deliverImmediately: true
            )
            exit(0)
        }
    }

    var body: some Scene {
        // One main window. Closing it keeps the app and the session running;
        // the Dock icon or the menu bar reopens it, Quit ends both (plan 7.6).
        Window("NIMQO", id: MainWindow.id) {
            RootView(model: model)
                .environment(panels)
                .frame(minWidth: 720, minHeight: 480)
                .windowLook()
                .task { model.start() }
        }

        // Opened by the menu bar label when a call starts or rings.
        Window("Call", id: CallWindow.id) {
            CallWindow(model: model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.topTrailing)
        .commands {
            CommandGroup(replacing: .appInfo) {
                PanelCommand(title: "About NIMQO", panel: .about, panels: panels)
                ResetCommand(model: model)
            }
            CommandGroup(replacing: .appSettings) {
                PanelCommand(title: "Settings…", panel: .settings, panels: panels)
                    .keyboardShortcut(",")
            }
            ChatCommands(model: model)
        }

        MenuBarExtra {
            StatusMenu(model: model, panels: panels)
        } label: {
            let unread = model.chats.filter { !$0.quiet }.reduce(0) { $0 + $1.unread }
            Label("NIMQO", systemImage: model.statusSymbol)
                .labelStyle(.iconOnly)
                .modifier(ShowsWindowOnRequest())
                .modifier(OpensCallWindow(calls: model.calls))
                .accessibilityValue(unread > 0 ? "\(model.statusText), \(unread) unread" : model.statusText)
            if unread > 0 {
                Text("\(unread)")
            }
        }
    }
}

enum MainWindow {
    static let id = "main"
    /// Posted by a second launch. Anyone can post it; all it does is show
    /// the window.
    static let show = Notification.Name("app.nimqo.show-main-window")
}

/// On the menu bar label, which lives as long as the app (the window may
/// be closed): opens the window when a second launch asks.
private struct ShowsWindowOnRequest: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onReceive(DistributedNotificationCenter.default().publisher(for: MainWindow.show)) { _ in
            openWindow(id: MainWindow.id)
            NSApp.activate()
        }
    }
}

/// Shows the call window whenever a call starts, from the menu bar label,
/// which lives as long as the app.
private struct OpensCallWindow: ViewModifier {
    let calls: CallStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: calls.current?.started) { _, started in
            if started != nil {
                openWindow(id: CallWindow.id)
            }
        }
    }
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

/// Kept small on purpose (plan 7.5): status, the latest chats, open,
/// Settings, quit. Not a second app.
struct StatusMenu: View {
    let model: CoreModel
    let panels: Panels
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.statusText)
        Divider()
        if !model.listed.isEmpty {
            Section("Recent") {
                ForEach(model.listed.prefix(5)) { chat in
                    Button(chat.unread > 0 ? "\(chat.title) (\(chat.unread))" : chat.title) {
                        open(chat.id)
                    }
                }
            }
            Divider()
        }
        Button("Open NIMQO") { open(nil) }
            .keyboardShortcut("o")
        PanelCommand(title: "Settings…", panel: .settings, panels: panels)
            .keyboardShortcut(",")
        Button("Quit NIMQO") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Brings the window forward, on `chat` if given.
    private func open(_ chat: ChatSummary.ID?) {
        openWindow(id: MainWindow.id)
        NSApp.activate()
        if let chat {
            model.selectedChat = chat
        }
    }
}
