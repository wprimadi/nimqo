import AppKit
import NimqoCore
import SwiftUI

/// Share, from the lightbox: the system's share menu (AirDrop, Messages,
/// Mail, Photos…) for a private copy of the file, opened from the button.
/// The copy goes once the share is done or cancelled, else at next launch.
struct ShareButton: View {
    let chat: String
    let message: ChatMessage
    let store: PictureStore
    @State private var anchor: NSView?

    var body: some View {
        Button("Share…", systemImage: "square.and.arrow.up") { share() }
            .background(ViewAnchor(view: $anchor))
    }

    private func share() {
        guard let anchor, let data = store.media(chat: chat, message: message) else { return }
        do {
            let file = try PictureStore.privateCopy(data, as: message.fileName(for: data))
            let picker = NSSharingServicePicker(items: [file])
            let cleanup = ShareCleanup(file: file)
            picker.delegate = cleanup
            // The picker holds its delegate weakly: keep it until done.
            objc_setAssociatedObject(picker, &ShareCleanup.key, cleanup, .OBJC_ASSOCIATION_RETAIN)
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// Removes the shared copy once the chosen service has it, or none was.
private final class ShareCleanup: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    nonisolated(unsafe) static var key: UInt8 = 0
    let file: URL

    init(file: URL) {
        self.file = file
    }

    func sharingServicePicker(_: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if let service {
            service.delegate = self
            objc_setAssociatedObject(service, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
        } else {
            remove()
        }
    }

    func sharingService(_: NSSharingService, didShareItems _: [Any]) {
        remove()
    }

    func sharingService(_: NSSharingService, didFailToShareItems _: [Any], error _: any Error) {
        remove()
    }

    private func remove() {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}

/// The AppKit view behind a SwiftUI one, to anchor AppKit popovers to.
private struct ViewAnchor: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_: NSView, context _: Context) {
        // Nothing changes.
    }
}
