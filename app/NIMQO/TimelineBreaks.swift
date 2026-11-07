import AppKit
import NimqoCore
import OSLog
import SwiftUI

/// Messages that start a new day (shown with a date above), and that start
/// a run from another sender or after a pause.
struct Breaks {
    var days = Set<Int64>()
    var runs = Set<Int64>()

    init() {}

    init(_ messages: [ChatMessage], calendar: Calendar = .current) {
        var previous: ChatMessage?
        for message in messages {
            let time = Date(timeIntervalSince1970: TimeInterval(message.timestampSecs))
            if let previous {
                let before = Date(timeIntervalSince1970: TimeInterval(previous.timestampSecs))
                if !calendar.isDate(before, inSameDayAs: time) {
                    days.insert(message.seq)
                }
                let otherSender = previous.fromMe != message.fromMe || previous.senderName != message.senderName
                if otherSender || message.timestampSecs - previous.timestampSecs > 300 {
                    runs.insert(message.seq)
                }
            } else {
                days.insert(message.seq)
            }
            previous = message
        }
    }
}

/// The date between messages of different days, as a small glass capsule.
struct DayChip: View {
    let date: Date

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return String(localized: "Today")
        }
        if calendar.isDateInYesterday(date) {
            return String(localized: "Yesterday")
        }
        let sameYear = calendar.isDate(date, equalTo: .now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).day().month(.wide)
            : .dateTime.day().month(.wide).year())
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .glassSurface(in: .capsule)
            .padding(.vertical, Theme.Spacing.small)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Rows not laid out yet are guessed from those that are; at the end of a
/// chat full of photos the guess is several times too tall. Scrolling up
/// lays the real rows out, the content shrinks by thousands of points,
/// and the scroll view stays where it was: past the rows, blank until
/// scrolled. When the content changes a lot and the offset does not follow
/// (or what is in view misses it entirely), go back to the message that
/// was in view. Logs numbers only.
struct BlankRecovery: ViewModifier {
    let count: Int
    let recover: () -> Void
    private static let log = Logger(subsystem: "app.nimqo.app", category: "timeline")

    private struct Shape: Equatable {
        var offset: Int
        var height: Int
        var blank: Bool
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Shape.self) { geometry in
                let all = CGRect(origin: .zero, size: geometry.contentSize)
                return Shape(offset: Int(geometry.visibleRect.minY), height: Int(geometry.contentSize.height),
                             blank: geometry.contentSize.height > 1 && !geometry.visibleRect.intersects(all))
            } action: { old, new in
                let stranded = abs(new.height - old.height) > 200 && abs(new.offset - old.offset) < 50
                guard new.blank || stranded else { return }
                let (before, after, offset) = (old.height, new.height, new.offset)
                Self.log.notice("""
                keeping place: height \(before, privacy: .public) -> \(after, privacy: .public) \
                at offset \(offset, privacy: .public), \(count, privacy: .public) messages
                """)
                // After the layout pass that left it there.
                DispatchQueue.main.async { recover() }
            }
        } else {
            content
        }
    }
}

/// The AppKit scroll view around the timeline, to nudge it. A blank
/// timeline came back with any scroll by hand, never with SwiftUI's own
/// scrollTo or scroll position, which saw nothing to move.
@MainActor
final class ScrollNudger {
    weak var scrollView: NSScrollView?

    /// What a wheel does: moves the clip view, a point and back, inside
    /// the content, so the rows in view are laid out again.
    func nudge() {
        guard let scrollView, let content = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let top = max(0, content.frame.height - clip.bounds.height)
        let offset = min(max(clip.bounds.origin.y, 0), top)
        let left = clip.bounds.origin.x
        clip.scroll(to: NSPoint(x: left, y: offset < top ? offset + 1 : max(0, offset - 1)))
        clip.scroll(to: NSPoint(x: left, y: offset))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Placed inside the timeline: hands its scroll view to the nudger.
struct ScrollFinder: NSViewRepresentable {
    let nudger: ScrollNudger

    func makeNSView(context _: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context _: Context) {
        if nudger.scrollView == nil {
            DispatchQueue.main.async { nudger.scrollView = view.enclosingScrollView }
        }
    }
}

/// Loads older messages near the top. On macOS 15 and later from the
/// scroll offset: a scroll position bound to a message made SwiftUI hold
/// that message where its guessed height put it, and when the guesses for
/// a chat full of photos collapsed, the view sat past every row, blank.
/// macOS 14 has no offset to read and keeps the bound position; `near`
/// gets the topmost message there, nil on 15.
struct TimelinePaging: ViewModifier {
    @Binding var topSeq: Int64?
    let near: (Int64?) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 600
            } action: { _, isNear in
                if isNear {
                    near(nil)
                }
            }
        } else {
            content
                .scrollPosition(id: $topSeq, anchor: .top)
                .onChange(of: topSeq) { _, top in
                    if top != nil {
                        near(top)
                    }
                }
        }
    }
}
