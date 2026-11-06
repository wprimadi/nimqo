import Foundation
@testable import NIMQO
import NimqoCore
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

    @Test func breaksMarkNewDaysAndNewRuns() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        func msg(_ seq: Int64, _ time: Int64, mine: Bool) -> ChatMessage {
            ChatMessage(
                id: "m", seq: seq, sender: "s", senderName: nil, contactName: nil, edited: false, hasMedia: false,
                reactions: nil, myReaction: nil, fromMe: mine, timestampSecs: time, kind: .text, body: nil,
                delivery: .none, reply: nil
            )
        }
        let day = Int64(86400)
        let breaks = Breaks([
            msg(1, day, mine: false), // first: new day
            msg(2, day + 60, mine: false), // same run
            msg(3, day + 120, mine: true), // other sender
            msg(4, day + 1000, mine: true), // after a pause
            msg(5, 2 * day + 10, mine: true), // next day
        ], calendar: utc)
        #expect(breaks.days == [1, 5])
        #expect(breaks.runs == [3, 4, 5])
    }
}
