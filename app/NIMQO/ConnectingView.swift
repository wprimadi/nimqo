import AppKit
import SwiftUI

/// While the connection comes up: the app icon breathing at the centre of
/// ripples, with two arcs circling it. Reduce Motion keeps it still.
struct ConnectingView: View {
    let text: String

    var body: some View {
        VStack(spacing: 28) {
            Emblem()
                .frame(width: 260, height: 260)
            VStack(spacing: 6) {
                Text(text).font(.title3.weight(.semibold))
                Label("End-to-end encrypted", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// Drawn by Core Animation in the render server: it keeps moving while the
/// app is busy bringing the connection up (a SwiftUI timeline froze then,
/// on slower Macs), and costs the app nothing per frame.
private struct Emblem: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context _: Context) -> EmblemView {
        EmblemView()
    }

    func updateNSView(_ view: EmblemView, context _: Context) {
        view.still = reduceMotion
    }

    final class EmblemView: NSView {
        var still = false {
            didSet {
                if still != oldValue {
                    built = false
                    needsDisplay = true
                }
            }
        }

        private var built = false

        override var wantsUpdateLayer: Bool {
            true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            wantsLayer = true
            built = false
            needsDisplay = true
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            built = false
            needsDisplay = true
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            built = false
            needsDisplay = true
        }

        override func updateLayer() {
            guard let layer, !built, window != nil, bounds.width > 0 else { return }
            built = true
            layer.sublayers = nil
            // Colors resolved in this view's appearance (light or dark).
            var accent = CGColor.black
            var secondary = CGColor.black
            effectiveAppearance.performAsCurrentDrawingAppearance {
                accent = NSColor.controlAccentColor.cgColor
                secondary = NSColor.secondaryLabelColor.cgColor
            }
            let scale = window?.backingScaleFactor ?? 2
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            for ring in 0 ..< 3 {
                layer.addSublayer(ripple(at: center, color: accent, index: ring))
            }
            layer.addSublayer(arc(diameter: 128, length: 0.3, width: 3, color: accent, turn: -360.0 / 160))
            layer.addSublayer(arc(diameter: 112, length: 0.18, width: 2,
                                  color: secondary.copy(alpha: 0.6) ?? secondary, turn: 360.0 / 110))
            layer.addSublayer(icon(at: center, color: accent, scale: scale))
        }

        /// A ring rising from the icon and fading as it spreads.
        private func ripple(at center: CGPoint, color: CGColor, index: Int) -> CALayer {
            let ring = CAShapeLayer()
            let side = bounds.width
            ring.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = color
            ring.lineWidth = 1.5
            ring.opacity = still ? 0 : 0.45
            guard !still else { return ring }
            let period = 2.6
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 92 / side
            grow.toValue = 1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.45
            fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = period
            group.repeatCount = .infinity
            // Spread evenly, already under way when shown.
            group.timeOffset = period * Double(index) / 3
            ring.add(group, forKey: "ripple")
            return ring
        }

        /// One arc of a circle, turning once every `turn` seconds; clockwise
        /// when negative.
        private func arc(diameter: CGFloat, length: CGFloat, width: CGFloat, color: CGColor, turn: Double) -> CALayer {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let arc = CAShapeLayer()
            arc.frame = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                               width: diameter, height: diameter)
            arc.path = CGPath(ellipseIn: arc.bounds, transform: nil)
            arc.fillColor = nil
            arc.strokeColor = color
            arc.lineWidth = width
            arc.lineCap = .round
            arc.strokeEnd = length
            guard !still else { return arc }
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = (turn < 0 ? -2 : 2) * Double.pi
            spin.duration = abs(turn)
            spin.repeatCount = .infinity
            arc.add(spin, forKey: "spin")
            return arc
        }

        /// The app icon, breathing, with a glow that swells with it.
        private func icon(at center: CGPoint, color: CGColor, scale: CGFloat) -> CALayer {
            let icon = CALayer()
            icon.frame = CGRect(x: center.x - 42, y: center.y - 42, width: 84, height: 84)
            icon.contents = NSApp.applicationIconImage.layerContents(forContentsScale: scale)
            icon.contentsScale = scale
            icon.contentsGravity = .resizeAspect
            icon.shadowColor = color
            icon.shadowOffset = .zero
            icon.shadowRadius = 18
            icon.shadowOpacity = 0.35
            guard !still else { return icon }
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.965
            breathe.toValue = 1.035
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.2
            glow.toValue = 0.5
            let group = CAAnimationGroup()
            group.animations = [breathe, glow]
            group.duration = .pi / 2.2
            group.autoreverses = true
            group.repeatCount = .infinity
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            icon.add(group, forKey: "breathe")
            return icon
        }
    }
}
