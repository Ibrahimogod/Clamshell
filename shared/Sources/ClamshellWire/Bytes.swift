/// Errors raised while decoding wire data. Decoders never trap on malformed input; they throw.
public enum WireError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case varintOverflow
    case varintTooLong
    case lengthTooLarge(Int)
    case invalidUTF8
    case unsupportedCritical(tag: UInt64)
    case missingField(tag: UInt64)
    case duplicateField(tag: UInt64)
    case invalidValue(String)
    case unknownChannel(UInt8)
}

/// Upper bound on any single length-prefixed field. Large enough for one encoded video frame,
/// small enough that a hostile length can't make us allocate gigabytes.
public let wireMaxFieldLength = 16 * 1024 * 1024

/// Append-only big-endian byte writer.
public struct ByteWriter: Sendable {
    public private(set) var bytes: [UInt8]

    public init(capacity: Int = 64) {
        bytes = []
        bytes.reserveCapacity(capacity)
    }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }

    public mutating func u16(_ v: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 8))
        bytes.append(UInt8(truncatingIfNeeded: v))
    }

    public mutating func u32(_ v: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt32(shift))) }
    }

    public mutating func u64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: v >> UInt64(shift))) }
    }

    /// Unsigned LEB128.
    public mutating func varint(_ value: UInt64) {
        var v = value
        while v >= 0x80 {
            bytes.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        bytes.append(UInt8(v))
    }

    public mutating func raw<C: Collection>(_ data: C) where C.Element == UInt8 { bytes.append(contentsOf: data) }

    /// varint length followed by the bytes.
    public mutating func lengthPrefixed<C: Collection>(_ data: C) where C.Element == UInt8 {
        varint(UInt64(data.count))
        bytes.append(contentsOf: data)
    }
}

/// Bounds-checked big-endian reader over a byte array slice.
public struct ByteReader: Sendable {
    private let bytes: [UInt8]
    public private(set) var offset: Int
    private let end: Int

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
        self.offset = 0
        self.end = bytes.count
    }

    public init(_ slice: ArraySlice<UInt8>) { self.init(Array(slice)) }

    public var remaining: Int { end - offset }
    public var isAtEnd: Bool { offset >= end }

    private mutating func need(_ n: Int) throws {
        guard n >= 0, remaining >= n else { throw WireError.truncated(needed: n, available: remaining) }
    }

    public mutating func u8() throws -> UInt8 {
        try need(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func u16() throws -> UInt16 {
        try need(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    public mutating func u32() throws -> UInt32 {
        try need(4)
        var v: UInt32 = 0
        for i in 0..<4 { v = v << 8 | UInt32(bytes[offset + i]) }
        offset += 4
        return v
    }

    public mutating func u64() throws -> UInt64 {
        try need(8)
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(bytes[offset + i]) }
        offset += 8
        return v
    }

    public mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        for i in 0..<10 {
            let b = try u8()
            let low = UInt64(b & 0x7F)
            if i == 9 && low > 1 { throw WireError.varintOverflow }
            result |= low << shift
            if b & 0x80 == 0 { return result }
            shift += 7
        }
        throw WireError.varintTooLong
    }

    /// A varint that must fit an `Int` length within `wireMaxFieldLength`.
    public mutating func length() throws -> Int {
        let v = try varint()
        guard v <= UInt64(wireMaxFieldLength) else { throw WireError.lengthTooLarge(Int(clamping: v)) }
        return Int(v)
    }

    public mutating func bytes(_ n: Int) throws -> [UInt8] {
        try need(n)
        defer { offset += n }
        return Array(bytes[offset..<offset + n])
    }

    public mutating func lengthPrefixed() throws -> [UInt8] { try bytes(try length()) }

    public mutating func rest() -> [UInt8] {
        defer { offset = end }
        return Array(bytes[offset..<end])
    }
}

extension Array where Element == UInt8 {
    /// Lower-case hex, for fixtures and logs of non-secret data only.
    public var hex: String {
        let digits: [Character] = ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"]
        var s = ""
        s.reserveCapacity(count * 2)
        for b in self {
            s.append(digits[Int(b >> 4)])
            s.append(digits[Int(b & 0x0F)])
        }
        return s
    }

    /// Parses hex, ignoring whitespace. Returns nil on any invalid character or odd length.
    public init?(hex: String) {
        let chars = hex.filter { !$0.isWhitespace }
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var it = chars.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let h = hi.hexDigitValue, let l = lo.hexDigitValue else { return nil }
            out.append(UInt8(h << 4 | l))
        }
        self = out
    }
}
