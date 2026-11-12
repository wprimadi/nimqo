import NimqoCore
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

/// Loads older messages near the top, from the scroll offset: a scroll
/// position bound to a message made SwiftUI hold that message where its
/// guessed height put it, and when the guesses for a chat full of photos
/// collapsed, the view sat past every row, blank. macOS 14 has no offset
/// here; it reads one from AppKit (`legacyScrollGeometry`).
struct TimelinePaging: ViewModifier {
    let near: () -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top < 600
            } action: { _, isNear in
                if isNear {
                    near()
                }
            }
        } else {
            content
        }
    }
}

/// The timeline's rows, all of them laid out: a lazy stack guesses the
/// rows it has not laid out from those it has, and at the end of a chat
/// full of photos the guess was several times too tall; when it collapsed
/// the view sat past every row, blank until scrolled.
/// ponytail: every loaded message is laid out; fine for a few hundred,
/// a sized lazy layout if long histories get slow.
struct TimelineStack<Content: View>: View {
    nonisolated static var spacing: CGFloat {
        2
    }

    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: Self.spacing) { content }
    }
}

extension View {
    /// Runs when the view comes on screen in its scroll view.
    func onShown(_ action: @escaping () -> Void) -> some View {
        onShownChange {
            if $0 {
                action()
            }
        }
    }

    /// Whether the view is on screen in its scroll view, as that changes.
    @ViewBuilder
    func onShownChange(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(macOS 15, *) {
            onScrollVisibilityChange(threshold: 0.01, action)
        } else {
            onAppear { action(true) }.onDisappear { action(false) }
        }
    }
}

extension View {
    /// Opens at the end and stays there as content grows. On macOS 15 and
    /// later not for aligning short content: that drew an empty panel
    /// above it, so a short timeline sits at the top instead.
    @ViewBuilder
    func bottomAnchored() -> some View {
        if #available(macOS 15, *) {
            defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            defaultScrollAnchor(.bottom)
        }
    }
}
