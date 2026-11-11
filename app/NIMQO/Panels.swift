import NimqoCore
import SwiftUI

/// Settings and About open as sheets on the main window: modal, so the
/// window can neither be used nor brought in front of them until they
/// close (Done, Escape, or the close button).
@MainActor
@Observable
final class Panels {
    enum Panel: String, Identifiable {
        case settings, about

        var id: Self {
            self
        }
    }

    var shown: Panel?
}

/// The sheet's content, with the way out every sheet needs.
struct PanelSheet: View {
    let panel: Panels.Panel
    let core: Core?
    /// Connected to WhatsApp: what Settings asks of the server can come.
    let online: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            switch panel {
            case .settings:
                VStack(spacing: 0) {
                    SettingsView(core: core, online: online)
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding([.horizontal, .bottom], Theme.Spacing.large)
                    .padding(.top, Theme.Spacing.small)
                }
                .windowLook()
            case .about:
                AboutView()
                    .overlay(alignment: .topTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                            .glassButton()
                            .padding(14)
                            .environment(\.colorScheme, .dark)
                    }
            }
        }
        .onExitCommand { dismiss() }
    }
}

/// App menu items and the menu bar's Settings…: bring the main window
/// forward (it may be closed), then show the sheet on it.
struct PanelCommand: View {
    let title: String
    let panel: Panels.Panel
    let panels: Panels
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(title) {
            openWindow(id: MainWindow.id)
            NSApp.activate()
            panels.shown = panel
        }
    }
}
