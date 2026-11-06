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
