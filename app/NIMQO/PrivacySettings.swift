import NimqoCore
import SwiftUI

/// The account's WhatsApp privacy, as on the phone: read from the server
/// when Settings opens, each change sent at once and undone if refused.
struct AccountPrivacySection: View {
    let core: Core?
    /// Asked again when the connection comes back.
    let online: Bool
    @State private var settings: PrivacySettings?
    @State private var failed = false
    @State private var refused = false

    var body: some View {
        Section {
            if let settings {
                picker("Last seen", .lastSeen, [.everyone, .contacts, .nobody])
                picker("Online", .online, [.everyone, .sameAsLastSeen])
                picker("Profile photo", .profilePhoto, [.everyone, .contacts, .nobody])
                picker("About", .about, [.everyone, .contacts, .nobody])
                picker("Groups", .groupAdd, [.everyone, .contacts, .nobody])
                Toggle("Read receipts", isOn: Binding(
                    get: { settings.readReceipts != .nobody },
                    set: { change(.readReceipts, to: $0 ? .everyone : .nobody) }
                ))
            } else if !online {
                Label("Waiting for the connection to WhatsApp…", systemImage: "wifi.exclamationmark")
                    .foregroundStyle(.secondary)
            } else if failed {
                HStack {
                    Text("Couldn't load privacy settings.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Try Again") { Task { await load() } }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            Text("WhatsApp Privacy")
        } footer: {
            Text(refused ? "WhatsApp didn't accept the change. Check the connection and try again." :
                "Who can see these on your account. Turning read receipts off also hides other people's. " +
                "\"My contacts except…\" is set on the phone.")
                .foregroundStyle(refused ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
        .task(id: [core.map(ObjectIdentifier.init).hashValue, online.hashValue]) {
            if online {
                await load()
            }
        }
    }

    private func picker(_ title: LocalizedStringKey, _ setting: PrivacySetting, _ all: [PrivacyChoice]) -> some View {
        let current = settings.flatMap { Self.choice(of: setting, in: $0) }
        return Picker(title, selection: Binding(get: { current }, set: {
            if let choice = $0 {
                change(setting, to: choice)
            }
        })) {
            ForEach(all + (current == .contactsExcept ? [.contactsExcept] : []), id: \.self) { choice in
                Text(Self.name(choice)).tag(Optional(choice))
                    .selectionDisabled(choice == .contactsExcept)
            }
        }
    }

    private static func choice(of setting: PrivacySetting, in settings: PrivacySettings) -> PrivacyChoice? {
        switch setting {
        case .lastSeen: settings.lastSeen
        case .online: settings.online
        case .profilePhoto: settings.profilePhoto
        case .about: settings.about
        case .groupAdd: settings.groupAdd
        case .readReceipts: settings.readReceipts
        }
    }

    private static func name(_ choice: PrivacyChoice) -> LocalizedStringKey {
        switch choice {
        case .everyone: "Everyone"
        case .contacts: "My contacts"
        case .contactsExcept: "My contacts except…"
        case .nobody: "Nobody"
        case .sameAsLastSeen: "Same as last seen"
        }
    }

    private func load() async {
        guard let core else { return }
        failed = false
        settings = await core.privacySettings()
        failed = settings == nil
    }

    /// Shows the choice at once; puts the old one back if WhatsApp refuses.
    private func change(_ setting: PrivacySetting, to choice: PrivacyChoice) {
        guard let core, let before = settings else { return }
        settings = before.with(setting, choice)
        refused = false
        Task {
            if await !core.setPrivacy(setting: setting, choice: choice) {
                settings = before
                refused = true
            }
        }
    }
}

private extension PrivacySettings {
    func with(_ setting: PrivacySetting, _ choice: PrivacyChoice) -> PrivacySettings {
        var copy = self
        switch setting {
        case .lastSeen: copy.lastSeen = choice
        case .online: copy.online = choice
        case .profilePhoto: copy.profilePhoto = choice
        case .about: copy.about = choice
        case .groupAdd: copy.groupAdd = choice
        case .readReceipts: copy.readReceipts = choice
        }
        return copy
    }
}
