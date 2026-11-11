import AppKit
import SwiftUI

/// A picture blown up and blurred into a wash of its colours, over the
/// accent, darker at the bottom so text on it stays legible.
struct HeroBackdrop: View {
    let id: String
    let avatars: AvatarStore

    var body: some View {
        ZStack {
            LinearGradient(colors: [.accentColor.opacity(0.55), .accentColor.opacity(0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image = avatars.image(for: id) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 48)
                    .opacity(0.7)
                    .saturation(1.4)
            }
            LinearGradient(colors: [.clear, .black.opacity(0.25)], startPoint: .top, endPoint: .bottom)
        }
        .accessibilityHidden(true)
    }
}

/// The top of a profile card: the picture in a ring over its own colours,
/// then whatever names it. The ring is green while the person is online.
struct ProfileHero<Content: View>: View {
    let chat: ChatSummary
    let avatars: AvatarStore
    var online = false
    @ViewBuilder let content: () -> Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            Avatar(chat: chat, store: avatars, size: 104)
                .padding(4)
                .background {
                    Circle().fill(online ? AnyShapeStyle(Color.green.gradient) : AnyShapeStyle(ring))
                }
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .scaleEffect(shown || reduceMotion ? 1 : 0.8)
                .opacity(shown || reduceMotion ? 1 : 0)
            content()
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background { HeroBackdrop(id: chat.id, avatars: avatars) }
        .clipShape(.rect(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .onAppear {
            withAnimation(reduceMotion ? nil : .spring(duration: 0.5, bounce: 0.35)) { shown = true }
        }
    }

    private var ring: AngularGradient {
        AngularGradient(colors: [.accentColor, .accentColor.opacity(0.35), .white.opacity(0.8), .accentColor],
                        center: .center)
    }
}

/// A round-cornered tile under the hero: an icon over a word.
struct QuickAction: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(enabled ? tint : .secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 20)
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.primary.opacity(hovering && enabled ? 0.12 : 0.06),
                        in: .rect(cornerRadius: 14, style: .continuous))
            .scaleEffect(hovering && enabled && !reduceMotion ? 1.04 : 1)
            .contentShape(.rect(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { over in
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25, bounce: 0.3)) { hovering = over }
        }
    }
}

/// One part of a profile: a small heading over its content, on a tile.
struct InfoSection<Content: View, Accessory: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let accessory: () -> Accessory
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                accessory()
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.05), in: .rect(cornerRadius: 14, style: .continuous))
    }
}

extension InfoSection where Accessory == EmptyView {
    init(_ title: LocalizedStringKey, symbol: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, accessory: { EmptyView() }, content: content)
    }
}

/// A capsule on the hero: online, members, and the like.
struct HeroChip: View {
    let text: Text
    let symbol: String

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: .capsule)
    }
}

extension View {
    /// Scrolls rather than run off the screen: a popover taller than the
    /// screen is cut at its edges, its margins with it.
    func fitsScreen(padding: CGFloat) -> some View {
        modifier(ScreenFit(padding: padding))
    }
}

private struct ScreenFit: ViewModifier {
    let padding: CGFloat
    @State private var height: CGFloat?

    func body(content: Content) -> some View {
        // Room under the window's toolbar for the arrow and a margin.
        let cap = (NSScreen.main?.visibleFrame.height ?? 800) - 160
        ScrollView {
            content
                .padding(padding)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(height ?? cap, cap))
    }
}
