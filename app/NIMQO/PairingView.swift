import CoreImage.CIFilterBuiltins
import NimqoCore
import SwiftUI

struct PairingView: View {
    let model: CoreModel

    var body: some View {
        VStack(spacing: Theme.Spacing.medium) {
            if let failure = model.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let payload = model.qrPayload, let image = Self.qrImage(payload) {
                Text("Scan with WhatsApp > Linked devices > Link a device")
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: Theme.qrSide, height: Theme.qrSide)
                    .padding(Theme.Spacing.medium)
                    // Scanners need dark modules on light, in dark mode too.
                    .background(.white)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Label(statusText, systemImage: "arrow.triangle.2.circlepath")
                    .font(.title2)
            }
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusText: String {
        switch model.status {
        case nil, .connecting, .connected: "Connecting…"
        case .waitingForScan: "Waiting for QR code…"
        case .disconnected: "Disconnected, reconnecting…"
        case .loggedOut: "Logged out. This device was unlinked."
        }
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
