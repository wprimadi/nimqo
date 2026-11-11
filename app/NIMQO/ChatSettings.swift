import NimqoCore
import SwiftUI

/// One chat's starred messages, notifications and disappearing messages,
/// on a profile card. Changes go to every device of the account.
struct ChatSettings: View {
    let chat: ChatSummary
    let core: Core?
    /// A group whose settings only its admins may change.
    var locked = false
    let showStarred: () -> Void
    @State private var problem: String?

    private static let timers: [(String, UInt32)] = [
        (String(localized: "Off"), 0),
        (String(localized: "24 hours"), 86400),
        (String(localized: "7 days"), 604_800),
        (String(localized: "90 days"), 7_776_000),
    ]

    var body: some View {
        InfoSection("This chat", symbol: "slider.horizontal.3") {
            VStack(spacing: 2) {
                Button(action: showStarred) {
                    SettingRow(title: "Starred Messages", symbol: "star.fill", tint: .yellow, value: nil)
                }
                .buttonStyle(.plain)
                Menu { muteChoices } label: {
                    SettingRow(title: "Notifications", symbol: chat.muted ? "bell.slash.fill" : "bell.fill",
                               tint: .red, value: chat.muted ? String(localized: "Muted") : String(localized: "On"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                Menu { timerChoices } label: {
                    SettingRow(title: "Disappearing Messages", symbol: "timer", tint: .blue,
                               value: chat.timer ?? String(localized: "Off"))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .disabled(locked)
                .help(locked ? "Only admins can change this group's settings." : "")
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(core == nil)
        }
    }

    @ViewBuilder
    private var muteChoices: some View {
        if chat.muted {
            Button("Unmute", systemImage: "bell") { run { try await $0.setMuted(chatId: chat.id, muted: false) } }
        } else {
            Button("Mute for 8 Hours") { run { try await $0.muteFor(chatId: chat.id, seconds: 8 * 3600) } }
            Button("Mute for 1 Week") { run { try await $0.muteFor(chatId: chat.id, seconds: 7 * 86400) } }
            Button("Mute Always") { run { try await $0.setMuted(chatId: chat.id, muted: true) } }
        }
    }

    private var timerChoices: some View {
        Picker("Disappearing Messages", selection: Binding(get: { chat.timerSecs }, set: { secs in
            run { try await $0.setChatTimer(chatId: chat.id, seconds: secs) }
        })) {
            ForEach(Self.timers, id: \.1) { Text($0.0).tag($0.1) }
        }
        .pickerStyle(.inline)
    }

    private func run(_ change: @escaping (Core) async throws -> Void) {
        guard let core else { return }
        problem = nil
        Task {
            do {
                try await change(core)
            } catch {
                problem = CoreModel.message(for: error)
            }
        }
    }
}

/// A tinted icon, a name, and the current value or a chevron.
private struct SettingRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let tint: Color
    let value: String?
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: .rect(cornerRadius: 6, style: .continuous))
                .contentTransition(.symbolEffect(.replace))
            Text(title).foregroundStyle(enabled ? .primary : .secondary)
            Spacer(minLength: 8)
            if let value {
                Text(value).foregroundStyle(.secondary).contentTransition(.opacity)
            }
            Image(systemName: value == nil ? "chevron.right" : "chevron.up.chevron.down")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .font(.callout)
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(.primary.opacity(hovering && enabled ? 0.07 : 0), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}
