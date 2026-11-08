import AppKit
import SwiftUI

/// NIMQO > About NIMQO. The glass logo floats over a slow aurora in its own
/// colors, tilts toward the pointer and catches its light like the glass it
/// is drawn as; below it, the version (click to copy, for bug reports), who
/// made it and where to find them, and what it is built on.
struct AboutView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            LogoMark()
                .padding(.top, 36)
                .rise(appeared, step: 0)
            VStack(spacing: 6) {
                Text("NIMQO")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                    .foregroundStyle(
                        LinearGradient(colors: [.white, Brand.mint], startPoint: .top, endPoint: .bottom)
                    )
                Text("A WhatsApp client, designed for the Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VersionChip()
                    .padding(.top, 6)
            }
            .padding(.top, 8)
            .rise(appeared, step: 1)

            Maker()
                .padding(.top, 28)
                .rise(appeared, step: 2)

            Footer()
                .padding(.top, 24)
                .padding(.bottom, 22)
                .rise(appeared, step: 3)
        }
        .padding(.horizontal, 32)
        .frame(width: 480)
        .background { Aurora().ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.7, bounce: 0.25)) {
                appeared = true
            }
        }
        .onDisappear { appeared = false }
    }
}

/// The logo's own colors.
private enum Brand {
    static let mint = Color(red: 0.62, green: 1.0, blue: 0.72)
    static let green = Color(red: 0.24, green: 0.86, blue: 0.42)
    static let teal = Color(red: 0.05, green: 0.55, blue: 0.55)
    static let blue = Color(red: 0.12, green: 0.42, blue: 0.95)
    static let night = Color(red: 0.01, green: 0.05, blue: 0.07)
}

private extension View {
    /// Rises into place a beat after the step before it.
    func rise(_ shown: Bool, step: Int) -> some View {
        modifier(Rise(shown: shown, step: step))
    }
}

private struct Rise: ViewModifier {
    let shown: Bool
    let step: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 14)
            .animation(
                reduceMotion ? .easeOut(duration: 0.2)
                    : .spring(duration: 0.7, bounce: 0.2).delay(Double(step) * 0.08),
                value: shown
            )
    }
}

/// A slow drift of the logo's greens and blues over near-black. Still under
/// Reduce Motion; a plain gradient before macOS 15.
private struct Aurora: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Brand.night
            if #available(macOS 15, *) {
                TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
                    let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                    mesh(time)
                }
            } else {
                LinearGradient(colors: [Brand.teal.opacity(0.5), Brand.night, Brand.blue.opacity(0.35)],
                               startPoint: .top, endPoint: .bottom)
            }
            // Darker toward the bottom, where the small text sits.
            LinearGradient(colors: [.clear, Brand.night.opacity(0.85)], startPoint: .center, endPoint: .bottom)
        }
    }

    @available(macOS 15, *)
    private func mesh(_ time: TimeInterval) -> some View {
        let drift = { (speed: Double, phase: Double) in Float(sin(time * speed + phase) * 0.12) }
        return MeshGradient(
            width: 3, height: 3,
            points: [
                [0, 0], [0.5 + drift(0.21, 0), 0], [1, 0],
                [0, 0.45 + drift(0.17, 1)], [0.5 + drift(0.13, 2), 0.4 + drift(0.19, 3)], [1, 0.5 + drift(0.15, 4)],
                [0, 1], [0.5 + drift(0.11, 5), 1], [1, 1],
            ],
            colors: [
                Brand.teal.opacity(0.75), Brand.green.opacity(0.55), Brand.blue.opacity(0.7),
                Brand.night, Brand.teal.opacity(0.35), Brand.night,
                Brand.night, Brand.night, Brand.night,
            ]
        )
    }
}

/// The glass logo, large. It tilts toward the pointer and a highlight
/// follows it across the glass; a click makes it bounce. Neither under
/// Reduce Motion.
private struct LogoMark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Pointer position over the logo, -1 to 1 on each axis; nil away.
    @State private var pointer: CGPoint?
    @State private var pressed = false
    private let size: CGFloat = 200

    var body: some View {
        let tilt = pointer ?? .zero
        Image("Logo")
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .overlay {
                // Light catching the glass where the pointer is.
                if let pointer, !reduceMotion {
                    RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(
                        x: 0.5 + pointer.x * 0.4, y: 0.5 + pointer.y * 0.4
                    ), startRadius: 0, endRadius: size * 0.55)
                        .blendMode(.plusLighter)
                        .mask(Image("Logo").resizable())
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: Brand.green.opacity(0.45), radius: 40, y: 10)
            .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.y * -10), axis: (x: 1, y: 0, z: 0))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : tilt.x * 10), axis: (x: 0, y: 1, z: 0))
            .scaleEffect(pressed ? 0.92 : 1)
            .animation(.spring(duration: 0.5, bounce: 0.3), value: pointer)
            .animation(.spring(duration: 0.35, bounce: 0.55), value: pressed)
            .contentShape(.circle)
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    pointer = CGPoint(x: location.x / size * 2 - 1, y: location.y / size * 2 - 1)
                case .ended:
                    pointer = nil
                }
            }
            .onTapGesture {
                guard !reduceMotion else { return }
                pressed = true
                Task {
                    try? await Task.sleep(for: .milliseconds(120))
                    pressed = false
                }
            }
            .accessibilityLabel("NIMQO")
            .accessibilityAddTraits(.isImage)
    }
}

/// "Version 0.0.1 (1)"; a click copies it, and says so.
private struct VersionChip: View {
    @State private var copied = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(version, forType: .string)
            withAnimation(.snappy) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.snappy) { copied = false }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied" : version)
                    .contentTransition(.opacity)
            }
            .font(.callout.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: .capsule)
            .overlay { Capsule().strokeBorder(.white.opacity(0.12)) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? Brand.mint : .secondary)
        .help("Copy the version")
        .accessibilityLabel(copied ? "Copied" : "\(version), copy")
    }
}

/// Who made it: name, mail and web, then every profile.
private struct Maker: View {
    @State private var hovered: String?
    private static let profiles: [Profile] = [
        Profile(name: "GitHub", logo: "github",
                url: "https://github.com/wprimadi"),
        Profile(name: "LinkedIn", logo: "linkedin", url: "https://www.linkedin.com/in/wahyuprimadi"),
        Profile(name: "Hack The Box", logo: "hackthebox",
                url: "https://profile.hackthebox.com/profile/019f859a-988d-70d0-9355-d307aef7aa95"),
        Profile(name: "X", logo: "x", url: "https://x.com/wprimadi"),
        Profile(name: "Instagram", logo: "instagram", url: "https://www.instagram.com/wprimadi"),
        Profile(name: "YouTube", logo: "youtube", url: "https://www.youtube.com/@wprimadi"),
        Profile(name: "Facebook", logo: "facebook", url: "https://www.facebook.com/wahyuprimadi"),
    ]

    var body: some View {
        VStack(spacing: 14) {
            VStack(spacing: 2) {
                Text("Crafted by").font(.caption).foregroundStyle(.secondary).textCase(.uppercase).tracking(1.2)
                Text("Wahyu Primadi").font(.title2.weight(.semibold))
            }
            HStack(spacing: 10) {
                LinkPill(title: "wahyuprimadi.com", symbol: "globe", url: "https://wahyuprimadi.com", prominent: true)
                LinkPill(title: "saya@wahyuprimadi.com", symbol: "envelope.fill",
                         url: "mailto:saya@wahyuprimadi.com", prominent: false)
            }
            HStack(spacing: 8) {
                ForEach(Self.profiles) { ProfileButton(profile: $0, hovered: $hovered) }
            }
            // The one under the pointer is named, for those who don't know
            // every mark.
            Text(hovered ?? "Find me elsewhere")
                .font(.caption)
                .foregroundStyle(hovered == nil ? .tertiary : .secondary)
                .contentTransition(.opacity)
                .animation(.easeOut(duration: 0.15), value: hovered)
                .accessibilityHidden(true)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(.white.opacity(0.05), in: .rect(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.04)],
                                             startPoint: .top, endPoint: .bottom))
        }
    }
}

private struct Profile: Identifiable {
    let name: String
    /// The brand's own mark, from Simple Icons (CC0), in Brands/.
    let logo: String
    let url: String
    var id: String {
        name
    }
}

/// Lifts and lights up under the pointer, so it reads as clickable.
private struct LinkPill: View {
    let title: String
    let symbol: String
    let url: String
    let prominent: Bool
    @State private var hovering = false

    var body: some View {
        if let target = URL(string: url) {
            Link(destination: target) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        prominent ? AnyShapeStyle(LinearGradient(colors: [Brand.green, Brand.teal],
                                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            : AnyShapeStyle(.white.opacity(hovering ? 0.16 : 0.09)),
                        in: .capsule
                    )
                    .foregroundStyle(prominent ? Brand.night : .primary)
                    .shadow(color: prominent ? Brand.green.opacity(hovering ? 0.6 : 0.3) : .clear, radius: 12, y: 4)
                    .scaleEffect(hovering ? 1.04 : 1)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.spring(duration: 0.3, bounce: 0.3), value: hovering)
            .help(url.replacingOccurrences(of: "mailto:", with: ""))
        }
    }
}

private struct ProfileButton: View {
    let profile: Profile
    @Binding var hovered: String?
    @State private var hovering = false

    var body: some View {
        if let target = URL(string: profile.url) {
            Link(destination: target) {
                Image("Brands/\(profile.logo)")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .frame(width: 38, height: 38)
                    .background(
                        hovering ? AnyShapeStyle(Brand.green.opacity(0.25)) : AnyShapeStyle(.white.opacity(0.07)),
                        in: .circle
                    )
                    .overlay { Circle().strokeBorder(.white.opacity(hovering ? 0.3 : 0.1)) }
                    .foregroundStyle(hovering ? Brand.mint : .secondary)
                    .offset(y: hovering ? -2 : 0)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                hovering = inside
                if inside {
                    hovered = profile.name
                } else if hovered == profile.name {
                    hovered = nil
                }
            }
            .animation(.spring(duration: 0.3, bounce: 0.35), value: hovering)
            .help(profile.name)
            .accessibilityLabel(profile.name)
        }
    }
}

/// Open source, what it's built on, and what it is not.
private struct Footer: View {
    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if let repo = URL(string: "https://github.com/wprimadi/nimqo") {
                    Link("Source on GitHub", destination: repo)
                }
                Text("·")
                Text("MIT License")
                Text("·")
                if let core = URL(string: "https://github.com/oxidezap/whatsapp-rust") {
                    Link("Built on whatsapp-rust", destination: core)
                }
            }
            .tint(Brand.mint)
            Text("An independent app. Not affiliated with, endorsed by, or sponsored by WhatsApp or Meta.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Copyright © 2026 Wahyu Primadi")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
