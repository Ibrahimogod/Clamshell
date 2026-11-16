import Foundation

/// TAI64N timestamp (12 bytes, big-endian): 8 bytes of `2^62 + seconds` plus 4 bytes of nanoseconds.
/// Carried in handshake msg1 so the Mac rejects a replayed initiation (ADR-0001).
public struct TAI64N: Comparable, Sendable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws {
        guard bytes.count == 12 else { throw NoiseError.malformedMessage }
        self.bytes = bytes
    }

    public init(date: Date) {
        let t = date.timeIntervalSince1970
        let secs = UInt64(max(0, t.rounded(.down)))
        let nanos = UInt32(min(999_999_999, max(0, (t - t.rounded(.down)) * 1_000_000_000)))
        var b = [UInt8]()
        b.reserveCapacity(12)
        let label = (UInt64(1) << 62) &+ secs
        for shift in stride(from: 56, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: label >> UInt64(shift))) }
        for shift in stride(from: 24, through: 0, by: -8) { b.append(UInt8(truncatingIfNeeded: nanos >> UInt32(shift))) }
        bytes = b
    }

    public static func now() -> TAI64N { TAI64N(date: Date()) }

    public static func < (a: TAI64N, b: TAI64N) -> Bool { a.bytes.lexicographicallyPrecedes(b.bytes) }
}

/// Sliding anti-replay window over 2048 counters (RFC 6479-style bitmap).
/// `canAccept` is checked before decrypting (cheap reject); `mark` only after authentication succeeds.
public struct ReplayWindow: Sendable {
    public static let size: UInt64 = 2048
    private static let wordCount = Int(size / 64)

    private var bits = [UInt64](repeating: 0, count: ReplayWindow.wordCount)
    private var top: UInt64 = 0
    private var seenAny = false

    public init() {}

    public func canAccept(_ counter: UInt64) -> Bool {
        guard seenAny else { return true }
        if counter > top { return true }
        if top - counter >= Self.size { return false }
        return !isSet(counter)
    }

    /// Records `counter`. Returns false if it was a replay or too old (and records nothing).
    @discardableResult
    public mutating func mark(_ counter: UInt64) -> Bool {
        guard canAccept(counter) else { return false }
        if !seenAny {
            seenAny = true
            top = counter
        } else if counter > top {
            let advance = counter - top
            if advance >= Self.size {
                for i in bits.indices { bits[i] = 0 }
            } else {
                var c = top &+ 1
                while c <= counter {
                    clear(c)
                    if c == UInt64.max { break }
                    c += 1
                }
            }
            top = counter
        }
        set(counter)
        return true
    }

    private func position(_ c: UInt64) -> (Int, UInt64) {
        let bit = c % Self.size
        return (Int(bit / 64), UInt64(1) << (bit % 64))
    }

    private func isSet(_ c: UInt64) -> Bool {
        let (w, m) = position(c)
        return bits[w] & m != 0
    }

    private mutating func set(_ c: UInt64) {
        let (w, m) = position(c)
        bits[w] |= m
    }

    private mutating func clear(_ c: UInt64) {
        let (w, m) = position(c)
        bits[w] &= ~m
    }
}
