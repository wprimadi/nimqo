import Foundation
@testable import NIMQO
import Testing

struct ChatRowTests {
    @Test func stampShowsTimeYesterdayWeekdayOrDate() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        let day = { (days: Int) in calendar.date(byAdding: .day, value: -days, to: now)! }
        #expect(ChatRow.stamp(now, now: now) == now.formatted(date: .omitted, time: .shortened))
        #expect(ChatRow.stamp(day(1), now: now) == String(localized: "Yesterday"))
        #expect(ChatRow.stamp(day(3), now: now) == day(3).formatted(.dateTime.weekday(.wide)))
        #expect(ChatRow.stamp(day(30), now: now) == day(30).formatted(date: .numeric, time: .omitted))
    }
}
