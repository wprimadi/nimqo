import NimqoCore
import SwiftUI

extension ChatSummary {
    /// "typing…", "Ana is typing…", "recording audio…"; nil when quiet.
    static func activityText(_ activity: Activity?) -> String? {
        guard let activity else { return nil }
        return switch (activity.who, activity.recording) {
        case (nil, false): String(localized: "typing…")
        case (nil, true): String(localized: "recording audio…")
        case let (who?, false): String(localized: "\(who) is typing…")
        case let (who?, true): String(localized: "\(who) is recording audio…")
        }
    }
}

/// Three dots that light up one after another.
struct TypingDots: View {
    var size: CGFloat = 5
    var color: NSColor = .controlAccentColor

    var body: some View {
        Pulsing(symbol: nil, size: size, color: color)
    }
}

/// Three dots, or a symbol, fading in turn; still under Reduce Motion.
/// The fade runs in the render server and costs the app nothing per frame:
/// any SwiftUI animation, symbol effects and TimelineView included,
/// re-rendered the whole window every frame for as long as anyone in the
/// chat list was typing.
struct Pulsing: NSViewRepresentable {
    let symbol: String?
    let size: CGFloat
    let color: NSColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context _: Context) -> PulseView {
        PulseView()
    }

    func updateNSView(_ view: PulseView, context _: Context) {
        view.configure(symbol: symbol, size: size, color: color, still: reduceMotion)
    }

    final class PulseView: NSView {
        private var symbol: String?
        private var size: CGFloat = 5
        private var color = NSColor.labelColor
        private var built: String?
        private var still = false

        override var wantsUpdateLayer: Bool {
            true
        }

        override var intrinsicContentSize: NSSize {
            symbol == nil ? NSSize(width: size * 4.2, height: size) : NSSize(width: size, height: size)
        }

        func configure(symbol: String?, size: CGFloat, color: NSColor, still: Bool) {
            (self.symbol, self.size, self.color, self.still) = (symbol, size, color, still)
            wantsLayer = true
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }

        override func updateLayer() {
            guard let layer else { return }
            let key = "\(symbol ?? "") \(size) \(still)"
            if built != key {
                built = key
                build(in: layer)
            }
            // Resolved here, in the view's appearance (light or dark).
            let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(.init(paletteColors: [color]))
            let image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
                .withSymbolConfiguration(config)
            for part in layer.sublayers ?? [] {
                if let image {
                    part.contents = image
                } else {
                    part.backgroundColor = color.cgColor
                }
            }
        }

        private func build(in layer: CALayer) {
            layer.sublayers = nil
            for index in 0 ..< (symbol == nil ? 3 : 1) {
                let part = CALayer()
                part.frame = CGRect(x: CGFloat(index) * size * 1.6, y: 0, width: size, height: size)
                part.cornerRadius = symbol == nil ? size / 2 : 0
                part.contentsGravity = .resizeAspect
                part.contentsScale = window?.backingScaleFactor ?? 2
                if !still {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    (fade.fromValue, fade.toValue) = (1.0, 0.3)
                    fade.duration = 0.5
                    fade.autoreverses = true
                    fade.repeatCount = .infinity
                    fade.beginTime = CACurrentMediaTime() + Double(index) * 0.2
                    fade.fillMode = .backwards
                    part.add(fade, forKey: "pulse")
                }
                layer.addSublayer(part)
            }
        }
    }
}

/// In a chat list row, in place of the last message.
struct TypingLabel: View {
    let text: String
    let recording: Bool

    var body: some View {
        HStack(spacing: 5) {
            if recording {
                Pulsing(symbol: "mic.fill", size: 11, color: .controlAccentColor)
            } else {
                TypingDots(size: 4)
            }
            Text(text).lineLimit(1)
        }
        .foregroundStyle(.tint)
        .transition(.opacity.combined(with: .offset(y: 4)))
    }
}

/// At the end of the timeline while the other side is typing: an incoming
/// bubble of dots that grows in from its corner.
struct TypingBubble: View {
    let text: String
    let recording: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if recording {
                    Pulsing(symbol: "waveform", size: 16, color: .secondaryLabelColor)
                } else {
                    TypingDots(size: 7, color: .secondaryLabelColor)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.primary.opacity(0.08), in: .rect(cornerRadius: 16, style: .continuous))
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .transition(.scale(scale: 0.4, anchor: .bottomLeading).combined(with: .opacity))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}

/// One app, one chat list: one pending re-read.
@MainActor private var activityExpiry: Task<Void, Never>?

extension CoreModel {
    /// Typing ends without a signal when the "paused" one is lost: read
    /// the list again once the core has let it lapse.
    func expireActivity() {
        activityExpiry?.cancel()
        guard chats.contains(where: { $0.activity != nil }) else { return }
        activityExpiry = Task {
            try? await Task.sleep(for: .seconds(16))
            if !Task.isCancelled {
                reloadChats()
            }
        }
    }
}
