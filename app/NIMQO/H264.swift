import Foundation

/// H.264 framing. The call engine speaks Annex-B (units after `00 00 01`
/// start codes); VideoToolbox speaks AVCC (units after a 4-byte length).
enum H264 {
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    /// The units of an Annex-B access unit, without their start codes.
    static func units(annexB data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            guard bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 else {
                index += 1
                continue
            }
            if let begin = start {
                // A 4-byte start code leaves its leading zero on the previous unit.
                var end = index
                while end > begin, bytes[end - 1] == 0 {
                    end -= 1
                }
                units.append(Data(bytes[begin ..< end]))
            }
            index += 3
            start = index
        }
        if let begin = start, begin < bytes.count {
            units.append(Data(bytes[begin...]))
        }
        return units
    }

    /// The unit type: 5 a keyframe slice, 7 SPS, 8 PPS.
    static func type(of unit: Data) -> UInt8 {
        (unit.first ?? 0) & 0x1F
    }

    static func annexB(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { out, unit in
            out.append(contentsOf: startCode)
            out.append(unit)
        }
    }

    static func avcc(_ units: [Data]) -> Data {
        units.reduce(into: Data()) { out, unit in
            let size = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: size) { out.append(contentsOf: $0) }
            out.append(unit)
        }
    }

    /// The units of an AVCC buffer; stops at the first malformed length.
    static func units(avcc bytes: [UInt8]) -> [Data] {
        var units: [Data] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let size = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            guard size > 0, offset + size <= bytes.count else { break }
            units.append(Data(bytes[offset ..< offset + size]))
            offset += size
        }
        return units
    }
}
