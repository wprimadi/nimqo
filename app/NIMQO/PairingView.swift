import CoreImage.CIFilterBuiltins
import NimqoCore
import SwiftUI

/// Status before the session is up, and the two ways to link while pairing.
struct PairingView: View {
    let model: CoreModel
    @State private var method = Method.qrCode
    @State private var phoneNumber = ""

    enum Method: String, CaseIterable {
        case qrCode = "QR Code"
        case phone = "Phone Number"
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if model.state == .pairing {
                Text("Link NIMQO to WhatsApp").font(.title2.bold())
                Picker("Link with", selection: $method) {
                    ForEach(Method.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)
                switch method {
                case .qrCode: qrSection
                case .phone: phoneSection
                }
            } else if model.isResetting {
                ProgressView("Removing local data…")
            } else if [nil, .connecting, .reconnecting].contains(model.state) {
                ConnectingView(text: model.statusText)
            } else {
                Label(model.statusText, systemImage: model.statusSymbol)
                    .font(.title2)
                if model.state == .loggedOut {
                    Button("Remove Data and Link Again…") { model.confirmingReset = true }
                        .disabled(!model.canReset)
                }
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var qrSection: some View {
        if let payload = model.qrPayload, let image = Self.qrImage(payload) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: Theme.qrSide, height: Theme.qrSide)
                .padding(Theme.Spacing.medium)
                // Scanners need dark modules on light, in dark mode too.
                .background(.white, in: .rect(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .accessibilityLabel("Pairing QR code")
                .accessibilityHint("Scan it with your phone's camera from WhatsApp. It refreshes automatically.")
        } else {
            ProgressView("Waiting for a QR code…")
        }
        steps([
            "Open WhatsApp on your phone.",
            "Go to Settings > Linked devices > Link a device.",
            "Point the phone at this code. It refreshes on its own; scan the one shown now.",
        ])
    }

    @ViewBuilder private var phoneSection: some View {
        HStack {
            TextField("Your WhatsApp number, e.g. +62 812 3456 7890", text: $phoneNumber)
                .textFieldStyle(.roundedBorder)
                .textContentType(.telephoneNumber)
                .onSubmit(request)
            Button("Get Code", action: request)
                .disabled(phoneNumber.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: 420)
        if let code = model.pairCode {
            PairCodeTiles(code: code).id(code)
        }
        if let message = model.pairCodeMessage {
            Text(message).foregroundStyle(.secondary)
        }
        steps([
            "Enter the number of the WhatsApp account to link, then choose Get Code.",
            "On your phone, open WhatsApp > Settings > Linked devices > Link a device.",
            "Choose \"Link with phone number instead\" and type the code shown here.",
        ])
    }

    private func request() {
        model.requestPairCode(phoneNumber: phoneNumber)
    }

    /// Spelled out so the steps work without seeing the code.
    private func steps(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                Text("\(index + 1). \(line)")
            }
        }
        .frame(maxWidth: 420, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private static func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
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
            HStack(spacing: 6) {
                ForEach(Array(characters.enumerated()), id: \.offset) { index, character in
                    if index == 4 {
                        Text("–").font(.title).foregroundStyle(.tertiary)
                    }
                    Text(String(character))
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .frame(width: 42, height: 54)
                        .glassSurface(in: .rect(cornerRadius: 12))
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
