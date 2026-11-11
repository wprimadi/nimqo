import ServiceManagement
import SwiftUI

/// Open at Login: macOS keeps the setting (System Settings > General >
/// Login Items), so it is read from there each time, never stored here.
struct GeneralSection: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Section {
            Toggle("Open NIMQO at login", isOn: Binding(get: { opensAtLogin }, set: change))
            if SMAppService.mainApp.status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
        } header: {
            Text("General")
        } footer: {
            Text(problem ?? String(localized: "Starts in the menu bar when you log in, so messages arrive right away."))
                .foregroundStyle(problem == nil ? .secondary : Color.red)
        }
    }

    private func change(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }
}
