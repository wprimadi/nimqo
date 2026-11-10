import AppKit
import SwiftUI

/// Keeps a ringing call above other apps' windows; draggable by its
/// background throughout; every call starts in the top-right corner.
struct FloatingWindow: NSViewRepresentable {
    let floating: Bool

    func makeNSView(context _: Context) -> NSView {
        Corner()
    }

    /// Pins the window by its top-right corner, so growing for video spreads
    /// left and down instead of off the screen. SwiftUI would bring back
    /// wherever the last call's window was dragged; a new call starts in
    /// the corner again, and a drag moves the pin.
    private final class Corner: NSView {
        private static let margin: CGFloat = 12
        private var observers: [Any] = []
        private var pin: NSPoint?
        /// A resize moves the window too; only a move at this size is a drag.
        private var size: NSSize?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            observers = [watch(NSWindow.didResizeNotification, of: window),
                         watch(NSWindow.didMoveNotification, of: window)]
            // After SwiftUI has put the window where it last was.
            DispatchQueue.main.async { [weak self] in
                guard let self, let visible = self.window?.screen?.visibleFrame else { return }
                pin = NSPoint(x: visible.maxX - Self.margin, y: visible.maxY - Self.margin)
                follow()
            }
        }

        /// A move remembers the corner; a resize keeps it.
        private func watch(_ name: Notification.Name, of window: NSWindow) -> Any {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    name == NSWindow.didMoveNotification ? self?.remember() : self?.follow()
                }
            }
        }

        private func remember() {
            guard let frame = window?.frame, frame.size == size else { return }
            pin = NSPoint(x: frame.maxX, y: frame.maxY)
        }

        private func follow() {
            guard let window, let pin, let visible = window.screen?.visibleFrame else { return }
            let size = window.frame.size
            self.size = size
            let origin = NSPoint(x: max(visible.minX, min(pin.x - size.width, visible.maxX - size.width)),
                                 y: max(visible.minY, min(pin.y - size.height, visible.maxY - size.height)))
            if origin != window.frame.origin {
                window.setFrameOrigin(origin)
            }
        }
    }

    func updateNSView(_ view: NSView, context _: Context) {
        DispatchQueue.main.async {
            view.window?.level = floating ? .floating : .normal
            view.window?.isMovableByWindowBackground = true
        }
    }
}
