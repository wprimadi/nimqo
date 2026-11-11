import ServiceManagement
import SwiftUI

/// Open at Login: macOS keeps the setting (System Settings > General >
/// Login Items), so it is read from there each time, never stored here.
struct GeneralSection: View {
    @State private var opensAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?
    @AppStorage(LinkPreviews.key) private var sendsLinkPreviews = false

    var body: some View {
        Section {
            Toggle("Open NIMQO at login", isOn: Binding(get: { opensAtLogin }, set: change))
            if SMAppService.mainApp.status == .requiresApproval {
                Button("Allow in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
            }
            Toggle("Make previews for links I send", isOn: $sendsLinkPreviews)
        } header: {
            Text("General")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(problem ?? String(localized: "Starts in the menu bar at login, so messages arrive right away."))
                    .foregroundStyle(problem == nil ? .secondary : Color.red)
                Text("""
                A link preview is made by opening the page from this Mac, which tells that site your address. \
                Previews others send are always shown; nothing is fetched for them.
                """)
                .foregroundStyle(.secondary)
            }
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
