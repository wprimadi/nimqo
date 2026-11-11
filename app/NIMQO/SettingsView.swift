import NimqoCore
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, privacy, appearance

    var id: Self {
        self
    }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .appearance: "Appearance"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .general: "How NIMQO starts and what it sends with your links."
        case .privacy: "Who sees what on your account, and what you give away."
        case .appearance: "The glass NIMQO's windows are made of."
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .privacy: "hand.raised.fill"
        case .appearance: "paintbrush.pointed.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: .gray
        case .privacy: .blue
        case .appearance: .purple
        }
    }
}

/// Settings (⌘,), a sheet on the main window (see `Panels`): a sidebar of
/// panes beside the chosen one. A fixed size, so the sheet never runs
/// under the Dock; a long pane scrolls.
struct SettingsView: View {
    let core: Core?
    let online: Bool
    @AppStorage("settingsPane") private var pane = SettingsPane.general
    @Namespace private var selection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.5)
            ZStack {
                detail.id(pane)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .offset(y: 14).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(alignment: .top) {
                // The pane's color, glowing down from the top.
                LinearGradient(colors: [pane.tint.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            .clipped()
        }
        .frame(width: 720, height: 460)
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0.2), value: pane)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Image("Logo")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)
                    .shadow(color: Brand.green.opacity(0.45), radius: 8, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Settings").font(.headline)
                    Text("NIMQO").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 16)
            ForEach(SettingsPane.allCases) { option in
                PaneButton(pane: option, selected: pane == option, namespace: selection) { pane = option }
            }
            Spacer()
        }
        .padding(12)
        .padding(.top, 8)
        .frame(width: 200, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(.primary.opacity(0.04))
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(pane.tint.gradient, in: .rect(cornerRadius: 11, style: .continuous))
                    .shadow(color: pane.tint.opacity(0.5), radius: 10, y: 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pane.title).font(.title2.weight(.bold))
                    Text(pane.subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            Form {
                switch pane {
                case .general:
                    GeneralSection()
                case .privacy:
                    AccountPrivacySection(core: core, online: online)
                    StatusSection()
                case .appearance:
                    GlassSection()
                }
            }
            .formStyle(.grouped)
            // The form's own opaque backdrop hid the window's glass and tint.
            .scrollContentBackground(.hidden)
        }
    }
}

/// A sidebar row; the selection slides between rows.
private struct PaneButton: View {
    let pane: SettingsPane
    let selected: Bool
    let namespace: Namespace.ID
    let choose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 10) {
                Image(systemName: pane.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(pane.tint.gradient, in: .rect(cornerRadius: 6, style: .continuous))
                    .symbolEffect(.bounce, value: selected)
                Text(pane.title).font(.callout.weight(selected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.primary.opacity(0.1))
                        .matchedGeometryEffect(id: "selection", in: namespace)
                } else if hovering {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.primary.opacity(0.05))
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct StatusSection: View {
    @AppStorage(StatusStore.receiptsKey) private var sendsStatusReceipts = true

    var body: some View {
        Section {
            Toggle("Tell people when I view their status", isOn: $sendsStatusReceipts)
        } header: {
            Text("Status")
        } footer: {
            Text("When off, you can watch status updates without the poster seeing you in their viewers.")
                .foregroundStyle(.secondary)
        }
    }
}

/// The glass look, each shown as a small sample, and its opacity.
private struct GlassSection: View {
    @AppStorage(GlassLook.key) private var look = GlassLook.dark
    @AppStorage(GlassLook.opacityKey) private var opacity = 0.5
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Section {
            HStack(spacing: Theme.Spacing.medium) {
                ForEach(GlassLook.allCases) { option in
                    LookTile(option: option, look: $look, opacity: opacity)
                }
            }
            .frame(maxWidth: .infinity)
            Text(look.detail).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } header: {
            Text("Glass")
        }
        Section {
            Slider(value: $opacity, in: 0 ... 1) {
                Text("Opacity")
            } minimumValueLabel: {
                Text("See-through")
            } maximumValueLabel: {
                Text("Solid")
            }
            .accessibilityValue("\(Int(opacity * 100)) percent")
            Button("Reset Opacity") { opacity = 0.5 }
                .disabled(opacity == 0.5)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help("Back to the look as designed")
        } footer: {
            if reduceTransparency || contrast == .increased {
                Text("Reduce Transparency or Increase Contrast is on in macOS, so the window stays solid.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct LookTile: View {
    let option: GlassLook
    /// A binding, not a flag: a Form row kept its first value otherwise.
    @Binding var look: GlassLook
    let opacity: Double

    private var selected: Bool {
        look == option
    }

    private func choose() {
        look = option
    }

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Theme.Spacing.small) {
                ZStack {
                    LinearGradient(
                        colors: [.indigo, .teal, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    GlassTint(look: option, opacity: opacity)
                }
                .frame(width: 100, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(
                            selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary),
                            lineWidth: selected ? 3 : 1
                        )
                }
                .scaleEffect(selected ? 1.04 : 1)
                .animation(.spring(duration: 0.3, bounce: 0.4), value: selected)
                .environment(\.colorScheme, option.scheme ?? .dark)
                Text(option.title).font(.callout)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) glass")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
