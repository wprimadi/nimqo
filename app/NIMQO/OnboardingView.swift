import SwiftUI

/// First run: what NIMQO is and what using it means, before any connection
/// is made (plan 4, 11.3, 21).
struct OnboardingView: View {
    let model: CoreModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text("Welcome to NIMQO")
                .font(.largeTitle.bold())
            Text("A native Mac app for your WhatsApp account. Before you link it, please read this.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                point(
                    "person.badge.shield.checkmark",
                    "Unofficial",
                    "NIMQO is an independent, open-source app. It is not affiliated with, endorsed by, or " +
                        "sponsored by WhatsApp or Meta, and uses an independently maintained implementation " +
                        "of the WhatsApp Web protocol."
                )
                point(
                    "exclamationmark.triangle",
                    "Your account",
                    "WhatsApp may restrict accounts that use unofficial apps, and compatibility can break " +
                        "when WhatsApp changes. Use it at your own risk."
                )
                point(
                    "lock",
                    "Stored on this Mac, encrypted",
                    "Messages and keys stay on this Mac, encrypted with a key in your Keychain. If that " +
                        "Keychain item is lost, local history cannot be recovered and you link again."
                )
                point(
                    "iphone",
                    "Linking",
                    "NIMQO links like WhatsApp Web: scan a QR code, or enter a code on your phone. " +
                        "Your phone stays the main device."
                )
            }
            .padding(.vertical, Theme.Spacing.small)

            HStack {
                Spacer()
                Button("I Understand, Continue") { model.acceptDisclosure() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: 560)
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func point(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.medium) {
            Image(systemName: symbol)
                .frame(width: 24)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
