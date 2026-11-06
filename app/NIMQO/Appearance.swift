import AppKit
import SwiftUI

/// The look of the glass: following macOS, clear over a see-through
/// window, or always dark or light. Chosen in Settings.
enum GlassLook: String, CaseIterable, Identifiable {
    case system, clear, dark, light

    static let key = "glassLook"

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .system: "System"
        case .clear: "Clear"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var detail: String {
        switch self {
        case .system: "Follows the macOS appearance."
        case .clear: "See-through glass; the desktop shows, blurred, behind the window."
        case .dark: "Always dark."
        case .light: "Always light."
        }
    }

    /// Nil follows macOS.
    var scheme: ColorScheme? {
        switch self {
        case .dark: .dark
        case .light: .light
        case .system, .clear: nil
        }
    }

    @available(macOS 26, *)
    var glass: Glass {
        self == .clear ? .clear : .regular
    }
}

/// Liquid Glass on macOS 26 and later; a material before it. Glass is for
/// the controls floating over content, never for content itself, and never
/// glass on glass.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @AppStorage(GlassLook.key) private var look = GlassLook.system

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(look.glass.interactive(), in: shape)
        } else {
            content.background(look == .clear ? .ultraThinMaterial : .regularMaterial, in: shape)
        }
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool
    @AppStorage(GlassLook.key) private var look = GlassLook.system

    func body(content: Content) -> some View {
        if prominent {
            if #available(macOS 26, *) {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.borderedProminent)
            }
        } else if #available(macOS 26.1, *) {
            content.buttonStyle(.glass(look.glass))
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// The window itself: see-through and blurred for the clear look, the
/// chosen light or dark otherwise.
private struct WindowLook: ViewModifier {
    @AppStorage(GlassLook.key) private var look = GlassLook.system

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(look.scheme)
            .background {
                if look == .clear {
                    BehindWindowBlur().ignoresSafeArea()
                }
            }
    }
}

/// Blurs what is behind the window (the desktop and other windows).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_: NSVisualEffectView, context _: Context) {}
}

extension View {
    func glassSurface(in shape: some Shape) -> some View {
        modifier(GlassSurface(shape: shape))
    }

    func glassButton(prominent: Bool = false) -> some View {
        modifier(GlassButton(prominent: prominent))
    }

    /// Glass shapes close together blend and morph into each other.
    @ViewBuilder
    func glassGroup(spacing: CGFloat) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    func windowLook() -> some View {
        modifier(WindowLook())
    }

    /// A bar floating over the bottom of a scroll view; on macOS 26 the
    /// content under it fades and blurs instead of showing through sharp.
    @ViewBuilder
    func bottomBar(@ViewBuilder _ bar: () -> some View) -> some View {
        if #available(macOS 26, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: bar)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: bar)
        }
    }
}

/// Settings (⌘,): the glass look, each shown as a small sample.
struct SettingsView: View {
    @AppStorage(GlassLook.key) private var look = GlassLook.system

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.medium) {
                    ForEach(GlassLook.allCases) { option in
                        LookTile(option: option, selected: option == look) { look = option }
                    }
                }
                Text(look.detail).foregroundStyle(.secondary)
            } header: {
                Text("Glass")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .windowLook()
    }
}

private struct LookTile: View {
    let option: GlassLook
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: Theme.Spacing.small) {
                ZStack {
                    LinearGradient(
                        colors: [.indigo, .teal, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(option == .clear ? 0.9 : 0.6)
                    Capsule()
                        .frame(width: 70, height: 22)
                        .opacity(0)
                        .glassSample(option)
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
                .environment(\.colorScheme, option.scheme ?? .dark)
                Text(option.title).font(.callout)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.title) glass")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private extension View {
    /// A sample of `option`'s glass, independent of the chosen one.
    @ViewBuilder
    func glassSample(_ option: GlassLook) -> some View {
        if #available(macOS 26, *) {
            glassEffect(option.glass, in: .capsule)
        } else {
            background(option == .clear ? .ultraThinMaterial : .regularMaterial, in: .capsule)
        }
    }
}
