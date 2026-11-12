import CoreImage.CIFilterBuiltins
import NimqoCore
import SwiftUI

/// Status before the session is up, and the two ways to link while pairing.
struct PairingView: View {
    let model: CoreModel

    /// Pairing, or between two pairing sessions.
    private var linking: Bool {
        model.state == .pairing || model.state == .notPaired || model.pairing.restarting
    }

    var body: some View {
        Group {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if linking {
                LinkingView(model: model)
            } else if model.isResetting {
                ProgressView("Removing local data…")
            } else if [nil, .connecting, .reconnecting].contains(model.state) {
                ConnectingView(text: model.statusText)
            } else {
                VStack(spacing: Theme.Spacing.medium) {
                    Label(model.statusText, systemImage: model.statusSymbol)
                        .font(.title2)
                    if model.state == .loggedOut {
                        Button("Remove Data and Link Again…") { model.confirmingReset = true }
                            .disabled(!model.canReset)
                    }
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The code (or the phone-number code) on the left, glowing; how to link
/// on the right. Stacked when the window is narrow.
private struct LinkingView: View {
    let model: CoreModel
    @State private var method = Method.qrCode
    @State private var phoneNumber = ""
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Method: String, CaseIterable {
        case qrCode = "QR Code"
        case phone = "Phone Number"
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 44) {
                stage
                guide
            }
            ScrollView {
                VStack(spacing: 28) {
                    stage
                    guide
                }
                .frame(maxWidth: .infinity)
            }
        }
        .opacity(shown ? 1 : 0)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.6, bounce: 0.15), value: shown)
        .onAppear { shown = true }
    }

    private var stage: some View {
        ZStack {
            // The icon's neon, as if the code lit the glass behind it.
            Circle()
                .fill(Theme.neon)
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .opacity(0.4)
                .accessibilityHidden(true)
            switch method {
            case .qrCode:
                QRTile(payload: model.qrPayload, clock: model.pairing) {
                    model.pairing.autoRefreshes = 0
                    model.refreshPairing()
                }
            case .phone:
                phoneStage
            }
        }
        .frame(width: 330, height: 320)
        .animation(reduceMotion ? nil : .spring(duration: 0.45, bounce: 0.2), value: method)
    }

    private var phoneStage: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let code = model.pairCode {
                PairCodeTiles(code: code).id(code)
            } else if model.pairing.awaitingCode {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 84, weight: .thin))
                    .foregroundStyle(Theme.neon)
                    .accessibilityHidden(true)
            }
            Text(model.pairCodeMessage ?? (model.pairCode == nil ? "Your code appears here." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Link NIMQO to WhatsApp")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.4)
                Text("Your phone stays the main device; this Mac joins it.")
                    .foregroundStyle(.secondary)
            }
            Picker("Link with", selection: $method) {
                ForEach(Method.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 12) {
                step(1, "Open WhatsApp on your phone.")
                step(2, "Go to Settings, then Linked devices, then Link a device.")
                switch method {
                case .qrCode:
                    step(3, "Point the phone at the code. A new one comes on its own.")
                case .phone:
                    step(3, "Choose Link with phone number instead, and type the code shown here.")
                }
            }
            .accessibilityElement(children: .combine)
            if method == .phone {
                numberField
            }
            Label("End-to-end encrypted", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 320, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.bold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.8))
                .frame(width: 22, height: 22)
                .background(Theme.neon, in: .circle)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 6 }
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var numberField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("+62 812 3456 7890", text: $phoneNumber)
                    .textFieldStyle(.plain)
                    .textContentType(.telephoneNumber)
                    .onSubmit(request)
                    .accessibilityLabel("Your WhatsApp number, in international format")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.primary.opacity(0.06), in: .capsule)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
            Button("Get Code", action: request)
                .glassButton(prominent: true)
                .controlSize(.large)
                .disabled(phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty || model.pairing.awaitingCode)
        }
    }

    private func request() {
        model.requestPairCode(phoneNumber: phoneNumber)
    }
}

/// The QR code on white (scanners need dark on light, in dark mode too),
/// the app icon at its centre, ringed by the time it has left. Lapsed, it
/// blurs under a button for a new one.
private struct QRTile: View {
    let payload: String?
    let clock: PairingClock
    let refresh: () -> Void

    private var lapsed: Bool {
        clock.expired && !clock.restarting
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
            if let payload, let image = Self.qrImage(payload) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 232, height: 232)
                    .overlay {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .padding(3)
                            .background(.white, in: .rect(cornerRadius: 12, style: .continuous))
                    }
                    .blur(radius: lapsed ? 8 : 0)
                    .opacity(lapsed ? 0.4 : 1)
                    // A new code fades in over the last.
                    .id(payload)
                    .transition(.opacity)
                    .accessibilityLabel("Pairing QR code")
                    .accessibilityHint("Scan it with WhatsApp on your phone. It refreshes automatically.")
            } else {
                ProgressView("Getting a code…")
                    .controlSize(.large)
                    .foregroundStyle(.black.opacity(0.6))
                    .environment(\.colorScheme, .light)
            }
            if lapsed {
                Button("New QR Code", systemImage: "arrow.clockwise", action: refresh)
                    .glassButton(prominent: true)
                    .controlSize(.large)
            }
        }
        .frame(width: 264, height: 264)
        .overlay {
            if !lapsed, payload != nil, let expires = clock.expires {
                CountdownRing(expires: expires, lifetime: clock.lifetime)
                    .padding(-8)
                    .accessibilityHidden(true)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: payload)
        .animation(.easeInOut(duration: 0.3), value: lapsed)
    }

    /// High error correction, so the icon over its centre does not matter.
    private static func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

/// The code in two groups of four, each character on its own tile, as the
/// phone asks for it; they deal in one by one. Copy puts it on the clipboard.
private struct PairCodeTiles: View {
    let code: String
    @State private var shown = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var characters: [Character] {
        Array(code.filter { $0.isLetter || $0.isNumber }.uppercased())
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            HStack(spacing: 5) {
                ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                    if index == 4 {
                        Text("–").font(.title2).foregroundStyle(.tertiary)
                    }
                    Text(String(character))
                        .font(.system(size: 26, weight: .semibold, design: .monospaced))
                        .frame(width: 34, height: 48)
                        .glassSurface(in: .rect(cornerRadius: 10))
                        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
                        .opacity(shown || reduceMotion ? 1 : 0)
                        .rotation3DEffect(.degrees(shown || reduceMotion ? 0 : -70), axis: (x: 1, y: 0, z: 0))
                        .animation(.spring(duration: 0.5, bounce: 0.35).delay(Double(index) * 0.05), value: shown)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Pairing code \(characters.map(String.init).joined(separator: " "))")
            Button(copied ? "Copied" : "Copy Code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(String(characters), forType: .string)
                withAnimation { copied = true }
            }
            .contentTransition(.symbolEffect(.replace))
            .controlSize(.small)
        }
        .onAppear { shown = true }
    }
}
