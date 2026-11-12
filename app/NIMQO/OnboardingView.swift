import SwiftUI

/// First run: what NIMQO is and what using it means, before any connection
/// is made (plan 4, 11.3, 21).
struct OnboardingView: View {
    let model: CoreModel
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Point {
        let symbol: String
        let color: Color
        let title: String
        let text: String
    }

    private static let points = [
        Point(
            symbol: "person.badge.shield.checkmark.fill", color: .indigo, title: "Unofficial",
            text: "NIMQO is an independent, open-source app. It is not affiliated with, endorsed by, or " +
                "sponsored by WhatsApp or Meta, and uses an independently maintained implementation " +
                "of the WhatsApp Web protocol."
        ),
        Point(
            symbol: "exclamationmark.triangle.fill", color: .orange, title: "Your account",
            text: "WhatsApp may restrict accounts that use unofficial apps, and compatibility can break " +
                "when WhatsApp changes. Use it at your own risk."
        ),
        Point(
            symbol: "lock.fill", color: .green, title: "Stored on this Mac, encrypted",
            text: "Messages and keys stay on this Mac, encrypted with a key in your Keychain. If that " +
                "Keychain item is lost, local history cannot be recovered and you link again."
        ),
        Point(
            symbol: "iphone.gen3", color: .blue, title: "Linking",
            text: "NIMQO links like WhatsApp Web: scan a QR code, or enter a code on your phone. " +
                "Your phone stays the main device."
        ),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                hero
                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    ForEach(0 ..< 2) { row in
                        GridRow {
                            ForEach(0 ..< 2) { column in
                                card(Self.points[row * 2 + column])
                                    .rise(shown, after: 0.35 + Double(row * 2 + column) * 0.08, still: reduceMotion)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 680)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.top, 36)
            .padding(.bottom, Theme.Spacing.medium)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .bottomBar { footer.rise(shown, after: 0.7, still: reduceMotion) }
        .onAppear { shown = true }
    }

    private var hero: some View {
        VStack(spacing: 12) {
            ZStack {
                // A soft glow in the icon's colors, as if it lit the glass.
                Circle()
                    .fill(Theme.neon)
                    .frame(width: 170, height: 170)
                    .blur(radius: 60)
                    .opacity(0.55)
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.3), radius: 18, y: 10)
            }
            .scaleEffect(shown || reduceMotion ? 1 : 0.7)
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.7, bounce: 0.3), value: shown)
            .accessibilityHidden(true)

            Text("Welcome to \(Text("NIMQO").foregroundStyle(Theme.neon))")
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.6)
                .multilineTextAlignment(.center)
                .rise(shown, after: 0.12, still: reduceMotion)
            Text("A native Mac app for your WhatsApp account. Before you link it, please take a moment to read this.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
                .rise(shown, after: 0.2, still: reduceMotion)
        }
    }

    private func card(_ point: Point) -> some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: point.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(point.color.gradient, in: .rect(cornerRadius: 10, style: .continuous))
                .shadow(color: point.color.opacity(0.4), radius: 8, y: 3)
                .accessibilityHidden(true)
            Text(point.title).font(.headline)
            Text(point.text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.05), in: shape)
        .overlay(shape.strokeBorder(.primary.opacity(0.09)))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            if let repo = URL(string: "https://github.com/wprimadi/nimqo") {
                Link(destination: repo) {
                    Label("Source on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.acceptDisclosure() } label: {
                HStack(spacing: 6) {
                    Text("I Understand, Continue")
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 6)
            }
            .glassButton(prominent: true)
            .controlSize(.extraLarge)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.vertical, Theme.Spacing.medium)
    }
}

private extension View {
    /// Rises into place after `delay`; under Reduce Motion it only fades.
    func rise(_ shown: Bool, after delay: Double, still: Bool) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown || still ? 0 : 16)
            .animation(
                still ? .easeOut(duration: 0.2) : .spring(duration: 0.6, bounce: 0.15).delay(delay),
                value: shown
            )
    }
}
