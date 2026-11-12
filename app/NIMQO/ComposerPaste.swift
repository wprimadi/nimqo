import AppKit
import SwiftUI

extension View {
    /// ⌘V while `active` in the main window: copied files, or a copied
    /// image with no text beside it, go to `paste` instead of the field.
    /// Plain text pastes as always.
    func pastesFiles(active: Bool, paste: @escaping ([URL]) -> Void) -> some View {
        modifier(FilePaste(active: active, paste: paste))
    }
}

private struct FilePaste: ViewModifier {
    let active: Bool
    let paste: ([URL]) -> Void
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                guard active else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v",
                          event.window === NSApp.mainWindow, event.window?.attachedSheet == nil,
                          let urls = Self.pasted(from: .general) else { return event }
                    paste(urls)
                    return nil
                }
            }
            .onDisappear {
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                }
                monitor = nil
            }
    }

    /// Copied files, or a copied image written out as PNG; nil for text.
    /// Text with a picture of itself (Word, Pages) stays text.
    static func pasted(from board: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let files = board.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !files.isEmpty {
            return files
        }
        guard board.string(forType: .string) == nil, let image = NSImage(pasteboard: board),
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        // One folder, emptied each time: a pasted image is not kept
        // longer than the next paste (and the system clears it anyway).
        let folder = FileManager.default.temporaryDirectory.appending(path: "Pasted", directoryHint: .isDirectory)
        for old in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: old)
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "Image.png")
        guard (try? png.write(to: file)) != nil else { return nil }
        return [file]
    }
}
