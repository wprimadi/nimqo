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

/// Some chats opened blank until scrolled: the scroll view sat where no
/// row was laid out. When what is in view misses the content entirely,
/// this goes to the latest message, after the layout pass that left it
/// there. Logs the geometry, numbers only, to pin down the cause.
struct BlankRecovery: ViewModifier {
    let count: Int
    let recover: () -> Void
    @State private var opened = Date.now
    private static let log = Logger(subsystem: "app.nimqo.app", category: "timeline")

    private struct Shape: Equatable {
        var offset: Int
        var height: Int
        var view: Int
        var blank: Bool
    }

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Shape.self) { geometry in
                let all = CGRect(origin: .zero, size: geometry.contentSize)
                return Shape(offset: Int(geometry.visibleRect.minY), height: Int(geometry.contentSize.height),
                             view: Int(geometry.visibleRect.height),
                             blank: geometry.contentSize.height > 1 && !geometry.visibleRect.intersects(all))
            } action: { old, new in
                let early = Date.now.timeIntervalSince(opened) < 6
                if early, abs(new.height - old.height) > 200 {
                    let (before, after, offset) = (old.height, new.height, new.offset)
                    Self.log.notice("""
                    timeline height \(before, privacy: .public) -> \(after, privacy: .public) \
                    at offset \(offset, privacy: .public), \(count, privacy: .public) messages
                    """)
                }
                guard new.blank, !old.blank else { return }
                let (offset, height, view) = (new.offset, new.height, new.view)
                Self.log.notice("""
                blank timeline: offset \(offset, privacy: .public), height \(height, privacy: .public), \
                view \(view, privacy: .public), \(count, privacy: .public) messages
                """)
                DispatchQueue.main.async { recover() }
            }
        } else {
            content
        }
    }
}
