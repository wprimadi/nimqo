import SwiftUI

/// Design tokens. Colors come from system semantic styles, so light and dark
/// mode, accent color, and Increase Contrast follow the user's settings.
enum Theme {
    enum Spacing {
        static let small: CGFloat = 8
        static let medium: CGFloat = 16
        static let large: CGFloat = 32
    }

    static let sidebarMinWidth: CGFloat = 240

    /// The app icon's neon: green into cyan into blue.
    static let neon = LinearGradient(
        colors: [Color(red: 0.35, green: 0.95, blue: 0.45), .cyan, Color(red: 0.2, green: 0.45, blue: 1)],
        startPoint: .leading, endPoint: .trailing
    )
}
