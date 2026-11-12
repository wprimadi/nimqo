import AppKit
import SwiftUI

/// Which timeline rows are drawn in full. A row far from the screen is an
/// empty stand-in of the height it had when last drawn, so the layout is
/// exact (no guessed heights, which once left the view blank) while only a
/// few screens of bubbles exist: every bubble kept alive made the window
/// cost hundreds of MB and redrew all of them on every hover.
/// A row never drawn yet, or changed since, is always drawn.
struct TimelineWindow {
    /// Heights rows had when last drawn, at `width`.
    private var heights: [Int64: CGFloat] = [:]
    private var width: CGFloat = 0
    /// What the scroll view shows, in content coordinates; nil until known
    /// (and on macOS 14, which has a lazy stack instead).
    private var visible: CGRect?
    /// False while the window is minimized, hidden or covered: then no row
    /// is drawn at all.
    var onScreen = true

    /// Rows to draw in full: those within a screen of the visible part.
    /// Nil draws every row.
    func live(_ seqs: [Int64]) -> Set<Int64>? {
        guard let visible else { return nil }
        guard onScreen else { return [] }
        let low = visible.minY - visible.height
        let high = visible.maxY + visible.height
        var live = Set<Int64>()
        // The padding and spinner above the first row are within the margin.
        var top: CGFloat = 0
        for seq in seqs {
            let height = heights[seq]
            let bottom = top + (height ?? 80)
            if height == nil || (bottom > low && top < high) {
                live.insert(seq)
            }
            top = bottom + TimelineStack<EmptyView>.spacing
        }
        return live
    }

    /// The stand-in height for a row not in `live`; nil draws it.
    func standIn(_ seq: Int64, live: Set<Int64>?) -> CGFloat? {
        guard let live, !live.contains(seq) else { return nil }
        return heights[seq]
    }

    mutating func measured(_ seq: Int64, height: CGFloat) {
        if abs((heights[seq] ?? -1) - height) > 0.5 {
            heights[seq] = height
        }
    }

    /// Rows whose message changed are drawn again to be measured again.
    mutating func forget(_ seqs: some Sequence<Int64>) {
        for seq in seqs {
            heights[seq] = nil
        }
    }

    /// Text wraps anew at another width: every height is stale.
    mutating func resized(to newWidth: CGFloat) {
        guard abs(newWidth - width) > 0.5 else { return }
        width = newWidth
        heights = [:]
    }

    /// Kept only once it moved a quarter screen: each change re-renders the
    /// timeline, and the margin of a screen hides the lag.
    mutating func scrolled(to rect: CGRect) {
        if let visible, abs(visible.minY - rect.minY) < rect.height / 4, visible.height == rect.height {
            return
        }
        visible = rect
    }
}

/// One timeline row: drawn and measured, or its stand-in.
struct TimelineRow<Content: View>: View {
    let standIn: CGFloat?
    let measured: (CGFloat) -> Void
    @ViewBuilder let content: Content

    var body: some View {
        if let standIn {
            Color.clear.frame(height: standIn)
        } else {
            VStack(spacing: TimelineStack<EmptyView>.spacing) { content }
                .onGeometryChange(for: CGFloat.self, of: \.size.height, action: measured)
        }
    }
}

extension View {
    /// Tells the window what its timeline shows, how wide it is, and
    /// whether it is on screen (macOS 15 and later).
    @ViewBuilder
    func timelineWindow(_ window: Binding<TimelineWindow>) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, rect in
                window.wrappedValue.scrolled(to: rect)
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { window.wrappedValue.resized(to: $0) }
            .background(WindowOcclusion { window.wrappedValue.onScreen = $0 })
        } else {
            self
        }
    }
}

/// Reports whether its window can be seen at all.
private struct WindowOcclusion: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context _: Context) -> Watcher {
        Watcher()
    }

    func updateNSView(_ view: Watcher, context _: Context) {
        view.changed = changed
    }

    final class Watcher: NSView {
        var changed: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let window = self?.window else { return }
                    self?.changed?(window.occlusionState.contains(.visible))
                }
            }
        }
    }
}
