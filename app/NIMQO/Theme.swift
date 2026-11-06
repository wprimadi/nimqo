import SwiftUI

/// Design tokens. Colors come from system semantic styles, so light and dark
/// mode, accent color, and Increase Contrast follow the user's settings.
enum Theme {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 32
    }

    static let qrSide: CGFloat = 280
    static let sidebarMinWidth: CGFloat = 240
}

/// Liquid Glass on macOS 26 and later; a material before it. Glass is for
/// the controls floating over content, never for content itself, and never
/// glass on glass.
extension View {
    @ViewBuilder
    func glassSurface(in shape: some Shape) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }

    @ViewBuilder
    func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
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
}
