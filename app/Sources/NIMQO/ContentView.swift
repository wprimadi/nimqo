import CoreImage.CIFilterBuiltins
import NimqoCore
import SwiftUI

struct ContentView: View {
    let model: CoreModel

    var body: some View {
        VStack(spacing: 20) {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            } else if let payload = model.qrPayload, let image = qrImage(payload) {
                Text("Scan with WhatsApp > Linked devices > Link a device")
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 280, height: 280)
                    .padding(16)
                    .background(.white)
                    .accessibilityLabel("Pairing QR code")
            } else {
                Label(statusText, systemImage: statusSymbol)
                    .font(.title2)
            }
        }
        .padding(32)
    }

    private var statusText: String {
        switch model.status {
        case nil, .connecting: "Connecting…"
        case .waitingForScan: "Waiting for QR code…"
        case .connected: "Connected"
        case .disconnected: "Disconnected, reconnecting…"
        case .loggedOut: "Logged out. This device was unlinked."
        }
    }

    private var statusSymbol: String {
        switch model.status {
        case .connected: "checkmark.circle"
        case .loggedOut: "xmark.circle"
        default: "arrow.triangle.2.circlepath"
        }
    }

    private func qrImage(_ payload: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}
