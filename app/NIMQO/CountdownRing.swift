import AppKit
import SwiftUI

/// A neon line around a rounded square that runs down until `expires`.
/// Core Animation draws it, so the countdown costs the app nothing per
/// frame; under Reduce Motion it stays full.
struct CountdownRing: NSViewRepresentable {
    let expires: Date
    let lifetime: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context _: Context) -> RingView {
        RingView()
    }

    func updateNSView(_ view: RingView, context _: Context) {
        view.configure(expires: expires, lifetime: lifetime, still: reduceMotion)
    }

    final class RingView: NSView {
        private var expires = Date.distantPast
        private var lifetime: TimeInterval = 1
        private var still = false
        private var built: String?

        override var wantsUpdateLayer: Bool {
            true
        }

        func configure(expires: Date, lifetime: TimeInterval, still: Bool) {
            (self.expires, self.lifetime, self.still) = (expires, max(lifetime, 1), still)
            wantsLayer = true
            needsDisplay = true
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            built = nil
            needsDisplay = true
        }

        override func updateLayer() {
            guard let layer, bounds.width > 0 else { return }
            let key = "\(expires.timeIntervalSinceReferenceDate) \(bounds.size) \(still)"
            guard built != key else { return }
            built = key
            layer.sublayers = nil
            let path = CGPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), cornerWidth: 34, cornerHeight: 34,
                              transform: nil)
            let track = CAShapeLayer()
            track.path = path
            track.fillColor = nil
            track.strokeColor = NSColor.white.withAlphaComponent(0.12).cgColor
            track.lineWidth = 3
            layer.addSublayer(track)

            let line = CAShapeLayer()
            line.path = path
            line.fillColor = nil
            line.strokeColor = NSColor.black.cgColor
            line.lineWidth = 3
            line.lineCap = .round
            let neon = CAGradientLayer()
            neon.frame = bounds
            neon.startPoint = CGPoint(x: 0, y: 0.5)
            neon.endPoint = CGPoint(x: 1, y: 0.5)
            neon.colors = [
                NSColor(red: 0.35, green: 0.95, blue: 0.45, alpha: 1).cgColor,
                NSColor.cyan.cgColor,
                NSColor(red: 0.2, green: 0.45, blue: 1, alpha: 1).cgColor,
            ]
            neon.mask = line
            layer.addSublayer(neon)

            let left = max(0, expires.timeIntervalSinceNow)
            let fraction = min(1, left / lifetime)
            line.strokeEnd = still ? 1 : 0
            guard !still, left > 0 else { return }
            let run = CABasicAnimation(keyPath: "strokeEnd")
            run.fromValue = fraction
            run.toValue = 0
            run.duration = left
            line.add(run, forKey: "countdown")
        }
    }
}
