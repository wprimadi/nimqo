import NimqoCore
import SwiftUI

/// The colours a text status can sit on, as sent (RGB).
struct StatusPalette: Identifiable, Hashable {
    let name: String
    let rgb: UInt32

    var id: UInt32 {
        rgb
    }

    var color: Color {
        Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }

    static let all = [
        StatusPalette(name: "Teal", rgb: 0x1E6E4F),
        StatusPalette(name: "Ocean", rgb: 0x1F5FA8),
        StatusPalette(name: "Violet", rgb: 0x6A3FB5),
        StatusPalette(name: "Berry", rgb: 0xB0285F),
        StatusPalette(name: "Coral", rgb: 0xD9573B),
        StatusPalette(name: "Amber", rgb: 0xC98A12),
        StatusPalette(name: "Slate", rgb: 0x3B4A5A),
    ]

    /// What the core accepts in one status.
    static let maxCharacters = 700

    /// Text size by length: a few words fill the card, a paragraph fits.
    static func size(for text: String) -> CGFloat {
        switch text.count {
        case ..<30: 40
        case ..<90: 32
        case ..<200: 25
        case ..<400: 20
        default: 17
        }
    }
}

extension StatusFont {
    var name: String {
        switch self {
        case .sans: "Sans"
        case .bold: "Bold"
        case .serif: "Serif"
        case .mono: "Typewriter"
        case .script: "Script"
        }
    }

    /// The nearest Mac font; the phone draws its own.
    func preview(size: CGFloat) -> Font {
        switch self {
        case .sans: .system(size: size, weight: .medium)
        case .bold: .system(size: size, weight: .black)
        case .serif: .system(size: size, weight: .bold, design: .serif)
        case .mono: .system(size: size * 0.9, weight: .bold, design: .monospaced)
        case .script: .custom("Snell Roundhand", size: size * 1.15).weight(.bold)
        }
    }

    var next: StatusFont {
        switch self {
        case .sans: .bold
        case .bold: .serif
        case .serif: .mono
        case .mono: .script
        case .script: .sans
        }
    }
}

/// The top of a status as viewers see it: the bar, then who posted it.
struct StatusCardHeader: View {
    /// Over a photo: shaded, so the white stays readable.
    let scrim: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Capsule().fill(.white.opacity(0.9)).frame(height: 3)
            HStack(spacing: 8) {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .frame(width: 28, height: 28)
                    .background(.white.opacity(0.25), in: .circle)
                Text("My Status").font(.subheadline.weight(.semibold))
                Text("now").font(.caption).opacity(0.75)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background {
            if scrim {
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
            }
        }
        .accessibilityHidden(true)
    }
}

/// How much of the limit is used; the number shows near the end.
struct CharacterRing: View {
    let count: Int

    private var used: Double {
        Double(count) / Double(StatusPalette.maxCharacters)
    }

    /// Red past the limit, orange near it.
    private func color(left: Int) -> Color {
        if left < 0 {
            return .red
        }
        return used > 0.9 ? .orange : .accentColor
    }

    var body: some View {
        let left = StatusPalette.maxCharacters - count
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 3)
            Circle().trim(from: 0, to: min(used, 1))
                .stroke(color(left: left),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if left < 50 {
                Text("\(left)").font(.system(size: 9, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(left < 0 ? .red : .secondary)
            }
        }
        .frame(width: 22, height: 22)
        .opacity(count == 0 ? 0 : 1)
        .animation(.snappy(duration: 0.2), value: count)
        .accessibilityLabel("\(left) characters left")
    }
}

/// Says the update went out; the check springs once per post.
struct PostedToast: View {
    let posts: Int

    var body: some View {
        Label("Posted to My Status", systemImage: "checkmark.circle.fill")
            .font(.headline)
            .symbolEffect(.bounce, value: posts)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .glassSurface(in: .capsule)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The background colours, one dot each.
struct StatusSwatches: View {
    @Binding var colour: StatusPalette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ForEach(StatusPalette.all) { option in
                Button { colour = option } label: {
                    Circle().fill(option.color)
                        .frame(width: 20, height: 20)
                        .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
                        .padding(3)
                        .overlay { Circle().strokeBorder(option == colour ? .primary : Color.clear, lineWidth: 2) }
                        .scaleEffect(option == colour && !reduceMotion ? 1.1 : 1)
                }
                .accessibilityLabel("\(option.name) background")
                .accessibilityAddTraits(option == colour ? .isSelected : [])
            }
        }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: colour)
    }
}
