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
                delivery: .none, reply: nil, mentions: []
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

@Test func `lightbox fit keeps the shape, centres, and caps the scale`() {
    let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    // A tiny video still grows to fill the width.
    let video = LightboxView.fit(CGSize(width: 160, height: 90), in: bounds, maxScale: .infinity)
    #expect(video == CGRect(x: 0, y: 75, width: 800, height: 450))
    // A small full photo stops at twice its size.
    let photo = LightboxView.fit(CGSize(width: 100, height: 100), in: bounds, maxScale: 2)
    #expect(photo == CGRect(x: 300, y: 200, width: 200, height: 200))
}

@Test func `mentions show names and only web and mail links open`() {
    let text = MessageText.attributed(
        "hi @178219684741240 see example.com, @62811 file:///etc/passwd",
        mentions: [Mention(user: "178219684741240", name: "Ana")]
    )
    #expect(String(text.characters) == "hi @Ana see example.com, @62811 file:///etc/passwd")
    let links = text.runs.compactMap(\.link)
    #expect(links.map(\.absoluteString) == ["http://example.com"])
}
