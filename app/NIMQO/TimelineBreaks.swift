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
