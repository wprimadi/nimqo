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
                .background(.white)
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
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityLabel("Pairing code \(code.map(String.init).joined(separator: " "))")
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
