/// TLV encoding (ADR-0011): `tag(varint) | len(varint) | value`.
///
/// - Unknown tags are skipped.
/// - Tags with `TLVTag.criticalBit` set must be understood; an unknown critical tag fails decoding
///   with `WireError.unsupportedCritical` instead of being silently ignored.
/// - Tag numbers are never reused.
public enum TLVTag {
    public static let criticalBit: UInt64 = 0x8000
}

public struct TLVField: Equatable, Sendable {
    public var tag: UInt64
    public var value: [UInt8]
    public init(tag: UInt64, value: [UInt8]) { self.tag = tag; self.value = value }
    public var isCritical: Bool { tag & TLVTag.criticalBit != 0 }
}

public struct TLVWriter: Sendable {
    public private(set) var writer = ByteWriter()
    public init() {}

    public var bytes: [UInt8] { writer.bytes }

    public mutating func bytes(_ tag: UInt64, _ value: [UInt8]) {
        writer.varint(tag)
        writer.lengthPrefixed(value)
    }

    public mutating func uint(_ tag: UInt64, _ value: UInt64) {
        var w = ByteWriter(capacity: 10)
        w.varint(value)
        bytes(tag, w.bytes)
    }

    public mutating func string(_ tag: UInt64, _ value: String) { bytes(tag, Array(value.utf8)) }

    public mutating func bool(_ tag: UInt64, _ value: Bool) { uint(tag, value ? 1 : 0) }

    /// Signed integer, zigzag-encoded (0, -1, 1, -2 … → 0, 1, 2, 3 …) so small magnitudes stay one byte.
    public mutating func sint(_ tag: UInt64, _ value: Int64) {
        uint(tag, UInt64(bitPattern: (value << 1) ^ (value >> 63)))
    }
}

/// Decoded TLV list. Lookups throw typed errors so message decoders stay short.
public struct TLVReader: Sendable {
    public let fields: [TLVField]

    /// - Parameter knownTags: tags this decoder understands. Unknown non-critical tags are kept in
    ///   `fields` (so a re-encoder could forward them) but are otherwise ignored.
    public init(_ bytes: [UInt8], knownTags: Set<UInt64>) throws {
        var r = ByteReader(bytes)
        var out: [TLVField] = []
        while !r.isAtEnd {
            let tag = try r.varint()
            let value = try r.lengthPrefixed()
            let field = TLVField(tag: tag, value: value)
            if field.isCritical && !knownTags.contains(tag) {
                throw WireError.unsupportedCritical(tag: tag)
            }
            out.append(field)
        }
        fields = out
    }

    public func all(_ tag: UInt64) -> [[UInt8]] { fields.filter { $0.tag == tag }.map(\.value) }

    public func optionalBytes(_ tag: UInt64) throws -> [UInt8]? {
        let matches = all(tag)
        guard matches.count <= 1 else { throw WireError.duplicateField(tag: tag) }
        return matches.first
    }

    public func requiredBytes(_ tag: UInt64) throws -> [UInt8] {
        guard let v = try optionalBytes(tag) else { throw WireError.missingField(tag: tag) }
        return v
    }

    public func optionalUInt(_ tag: UInt64) throws -> UInt64? {
        guard let b = try optionalBytes(tag) else { return nil }
        var r = ByteReader(b)
        let v = try r.varint()
        guard r.isAtEnd else { throw WireError.invalidValue("trailing bytes in varint field \(tag)") }
        return v
    }

    public func requiredUInt(_ tag: UInt64) throws -> UInt64 {
        guard let v = try optionalUInt(tag) else { throw WireError.missingField(tag: tag) }
        return v
    }

    public func optionalSInt(_ tag: UInt64) throws -> Int64? {
        guard let u = try optionalUInt(tag) else { return nil }
        return Int64(bitPattern: u >> 1) ^ -Int64(bitPattern: u & 1)
    }

    public func optionalString(_ tag: UInt64) throws -> String? {
        guard let b = try optionalBytes(tag) else { return nil }
        guard let s = String(validating: b, as: UTF8.self) else { throw WireError.invalidUTF8 }
        return s
    }

    public func requiredString(_ tag: UInt64) throws -> String {
        guard let s = try optionalString(tag) else { throw WireError.missingField(tag: tag) }
        return s
    }
}

extension UInt64 {
    /// Narrowing helper for decoded varints: throws instead of trapping.
    public func narrowed<T: FixedWidthInteger>(to: T.Type, field: String) throws -> T {
        guard let v = T(exactly: self) else { throw WireError.invalidValue("\(field) out of range: \(self)") }
        return v
    }
}
