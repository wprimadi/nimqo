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

    /// Whether a picture slice is intra-coded, so decoding can restart on it:
    /// an IDR slice, or a plain I slice (type 1 with slice_type I or SI),
    /// which is how some senders answer a keyframe request.
    static func isIntra(_ unit: Data) -> Bool {
        switch type(of: unit) {
        case 5: return true
        case 1:
            var reader = BitReader(bytes: [UInt8](unit.dropFirst()))
            guard reader.golomb() != nil, let slice = reader.golomb() else { return false }
            return slice % 5 == 2 || slice % 5 == 4
        default: return false
        }
    }

    /// Reads the slice header's first fields: unsigned Exp-Golomb codes.
    private struct BitReader {
        let bytes: [UInt8]
        var position = 0

        mutating func bit() -> Int? {
            guard position < bytes.count * 8 else { return nil }
            defer { position += 1 }
            return Int((bytes[position / 8] >> (7 - position % 8)) & 1)
        }

        mutating func golomb() -> Int? {
            var zeros = 0
            while true {
                guard let bit = bit() else { return nil }
                if bit == 1 {
                    break
                }
                zeros += 1
                guard zeros < 32 else { return nil }
            }
            var value = 0
            for _ in 0 ..< zeros {
                guard let bit = bit() else { return nil }
                value = value << 1 | bit
            }
            return (1 << zeros) - 1 + value
        }
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
