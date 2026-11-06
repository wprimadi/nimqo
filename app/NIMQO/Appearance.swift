import AppKit
import SwiftUI

/// The window is glass in every look: what is behind it shows through,
/// blurred. Clear lets most of it through; Dark and Light tint it.
enum GlassLook: String, CaseIterable, Identifiable {
    case clear, dark, light

    static let key = "glassLook"

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var detail: String {
        switch self {
        case .clear: "Clear glass: the desktop shows through, blurred. Follows the macOS appearance."
        case .dark: "Dark tinted glass."
        case .light: "Light tinted glass."
        }
    }

    /// Nil follows macOS.
    var scheme: ColorScheme? {
        switch self {
        case .clear: nil
        case .dark: .dark
        case .light: .light
        }
    }

    /// Laid over the blur; more of it is less see-through.
    var tint: Color {
        switch self {
        case .clear: .clear
        case .dark: .black.opacity(0.45)
        case .light: .white.opacity(0.55)
        }
    }
}

/// Liquid Glass on macOS 26 and later; a material before it. Glass is for
/// the controls floating over content, never for content itself, and never
/// glass on glass.
private struct GlassSurface<S: Shape>: ViewModifier {
    let shape: S
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private struct GlassButton: ViewModifier {
    let prominent: Bool

    func body(content: Content) -> some View {
        if prominent {
            if #available(macOS 26, *) {
                content.buttonStyle(.glassProminent)
            } else {
                content.buttonStyle(.borderedProminent)
            }
        } else if #available(macOS 26, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// The window itself: see-through, blurred, tinted by the look.
private struct WindowLook: ViewModifier {
    @AppStorage(GlassLook.key) private var look = GlassLook.dark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    /// Reduce Transparency or Increase Contrast: no see-through window.
    private var solid: Bool {
        reduceTransparency || contrast == .increased
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(look.scheme)
            .background {
                ZStack {
                    if solid {
                        Color(nsColor: .windowBackgroundColor)
                    } else {
                        // Clear lets a little of the desktop through
                        // unblurred: enough to see, not enough to read.
                        BehindWindowBlur().opacity(look == .clear ? 0.88 : 1)
                        look.tint
                    }
                }
                .ignoresSafeArea()
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: look)
            }
            .background(SeeThroughWindow(look: look))
    }
}

/// Makes the hosting window see-through, so the blur behind it shows
/// instead of the window's own opaque background.
private struct SeeThroughWindow: NSViewRepresentable {
    let look: GlassLook

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        // The window is attached after the first update.
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            // Also set on the window: preferredColorScheme going back to
            // nil keeps the last forced appearance there.
            window.appearance = switch look.scheme {
            case .dark: NSAppearance(named: .darkAqua)
            case .light: NSAppearance(named: .aqua)
            default: nil
            }
            if #available(macOS 26, *), let content = window.contentView {
                clearSidebarGlass(in: content)
            }
        }
    }
}

/// The sidebar sits on its own glass, over the window's blur; clear glass
/// makes the window read as one sheet.
/// ponytail: found by walking AppKit's views; if AppKit renames them the
/// sidebar keeps its regular glass, nothing breaks.
@available(macOS 26, *)
@MainActor
private func clearSidebarGlass(in view: NSView) {
    let inSplitView = String(describing: type(of: view.superview ?? view)).contains("SplitViewItem")
    if inSplitView, let glass = view as? NSGlassEffectView {
        glass.style = .clear
        return
    }
    for child in view.subviews {
        clearSidebarGlass(in: child)
    }
}

/// Blurs what is behind the window (the desktop and other windows).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context _: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
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
    @AppStorage(GlassLook.key) private var look = GlassLook.dark

    var body: some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.medium) {
                    ForEach(GlassLook.allCases) { option in
                        LookTile(option: option, look: $look)
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
    /// A binding, not a flag: a Form row kept its first value otherwise.
    @Binding var look: GlassLook

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
                    option.tint
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
