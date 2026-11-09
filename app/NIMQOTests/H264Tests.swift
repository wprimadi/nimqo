@testable import NIMQO
import XCTest

final class H264Tests: XCTestCase {
    private let sps = Data([0x67, 0x42, 0xE0, 0x1F])
    private let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    private let slice = Data([0x65, 0x88, 0x00, 0x00, 0x02, 0x10])

    func testAnnexBRoundTrip() {
        let units = [sps, pps, slice]
        XCTAssertEqual(H264.units(annexB: H264.annexB(units)), units)
    }

    func testThreeByteStartCodes() {
        let data = Data([0, 0, 1]) + sps + Data([0, 0, 1]) + slice
        XCTAssertEqual(H264.units(annexB: data), [sps, slice])
    }

    func testAVCCRoundTrip() {
        let units = [sps, pps, slice]
        XCTAssertEqual(H264.units(avcc: [UInt8](H264.avcc(units))), units)
    }

    func testTruncatedAVCCStops() {
        let bytes = [UInt8](H264.avcc([sps])) + [0, 0, 0, 9, 0x65]
        XCTAssertEqual(H264.units(avcc: bytes), [sps])
    }

    func testTypes() {
        XCTAssertEqual(H264.type(of: sps), 7)
        XCTAssertEqual(H264.type(of: pps), 8)
        XCTAssertEqual(H264.type(of: slice), 5)
    }

    /// Bits after the header: first_mb_in_slice ue(0) = 1, then slice_type.
    func testIntraSlices() {
        XCTAssertTrue(H264.isIntra(slice))
        XCTAssertTrue(H264.isIntra(Data([0x41, 0x88]))) // 1 0001000: slice_type 7, I
        XCTAssertTrue(H264.isIntra(Data([0x41, 0xB0]))) // 1 011: slice_type 2, I
        XCTAssertFalse(H264.isIntra(Data([0x41, 0xC0]))) // 1 1: slice_type 0, P
        XCTAssertFalse(H264.isIntra(Data([0x41, 0xA0]))) // 1 010: slice_type 1, B
        XCTAssertFalse(H264.isIntra(Data([0x41]))) // cut short
        XCTAssertFalse(H264.isIntra(sps))
    }
}
