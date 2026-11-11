@testable import NIMQO
import Testing

struct WaveformTests {
    /// A voice note's 64 bars once ran past its bubble; they are fitted to
    /// the room instead, keeping the peaks.
    @Test func barsFitTheirRoomAndKeepPeaks() {
        let bars = (0 ..< 64).map { UInt8($0 == 10 ? 100 : 20) }
        let fitted = WaveformBars.fit(bars, count: 40)
        #expect(fitted.count == 40)
        #expect(fitted.contains(100))
        #expect(WaveformBars.fit([30, 60], count: 4) == [30, 30, 60, 60])
        #expect(WaveformBars.fit(bars, count: 0).isEmpty)
    }
}
