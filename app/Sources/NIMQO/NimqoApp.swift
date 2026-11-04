import AppKit
import SwiftUI

@main
struct NimqoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = CoreModel()

    var body: some Scene {
        WindowGroup("NIMQO") {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 480)
                .task { model.start() }
        }
    }
}

/// Launched from `swift run` there is no app bundle, so macOS treats the
/// process as a background tool: no Dock icon and the window stays behind
/// the terminal. Make it a regular, frontmost app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        true
    }
}
