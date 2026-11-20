/// Textbook RSA (`m^e mod n`, no padding), which the TP-Link web UI uses to sign its requests with the
/// router's 512-bit public key. Only the public operation: nothing secret is computed here, so plain
/// shift-and-add arithmetic is enough. It's quick for keys this small (a few hundred microseconds).
struct RawRSA: Sendable {
    /// Big-endian bytes of the modulus and the exponent.
    let modulus: [UInt8]
    let exponent: [UInt8]

    /// Bytes per block: the modulus length.
    var blockSize: Int { modulus.count }

    init?(modulusHex: String, exponentHex: String) {
        guard let n = Self.bytes(hex: modulusHex), let e = Self.bytes(hex: exponentHex) else { return nil }
        let trimmed = Array(n.drop { $0 == 0 })
        guard trimmed.count >= 16, !e.allSatisfy({ $0 == 0 }) else { return nil }
        modulus = trimmed
        exponent = Array(e.drop { $0 == 0 })
    }

    /// `block^e mod n`, as big-endian bytes the size of the modulus. `block` must be that size too.
    func encrypt(_ block: [UInt8]) -> [UInt8]? {
        guard block.count == blockSize else { return nil }
        let n = Num(bigEndian: modulus, limbs: limbs)
        var m = Num(bigEndian: block, limbs: limbs)
        guard m < n else { return nil }
        var result = Num(bigEndian: [1], limbs: limbs)
        // Left to right over the exponent's bits.
        var started = false
        for byte in exponent {
            for bit in (0..<8).reversed() {
                if started { result = Self.mulMod(result, result, n) }
                if byte >> bit & 1 == 1 {
                    result = started ? Self.mulMod(result, m, n) : m
                    started = true
                }
            }
        }
        m = result
        return m.bigEndian(count: blockSize)
    }

    /// One spare limb, so sums of two numbers below `n` never overflow.
    private var limbs: Int { (modulus.count + 3) / 4 + 1 }

    /// `a·b mod n` by doubling and adding over the bits of `b` (both already below `n`).
    private static func mulMod(_ a: Num, _ b: Num, _ n: Num) -> Num {
        var r = Num(zero: a.limbs.count)
        for i in (0..<b.limbs.count).reversed() {
            let w = b.limbs[i]
            for bit in (0..<32).reversed() {
                r.shiftLeftOne()
                if r >= n { r.subtract(n) }
                if w >> UInt32(bit) & 1 == 1 {
                    r.add(a)
                    if r >= n { r.subtract(n) }
                }
            }
        }
        return r
    }

    static func bytes(hex: String) -> [UInt8]? {
        var s = Array(hex.utf8)
        if s.count % 2 == 1 { s.insert(UInt8(ascii: "0"), at: 0) }
        var out: [UInt8] = []
        out.reserveCapacity(s.count / 2)
        var i = 0
        while i < s.count {
            guard let hi = nibble(s[i]), let lo = nibble(s[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out.isEmpty ? nil : out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): c - UInt8(ascii: "A") + 10
        default: nil
        }
    }

    /// Fixed-width unsigned integer, little-endian 32-bit limbs.
    private struct Num: Comparable {
        var limbs: [UInt32]

        init(zero count: Int) { limbs = Array(repeating: 0, count: count) }

        init(bigEndian bytes: [UInt8], limbs count: Int) {
            limbs = Array(repeating: 0, count: count)
            for (i, b) in bytes.reversed().enumerated() where i / 4 < count {
                limbs[i / 4] |= UInt32(b) << UInt32(8 * (i % 4))
            }
        }

        func bigEndian(count: Int) -> [UInt8] {
            (0..<count).reversed().map { i in
                let limb = i / 4 < limbs.count ? limbs[i / 4] : 0
                return UInt8(truncatingIfNeeded: limb >> UInt32(8 * (i % 4)))
            }
        }

        mutating func shiftLeftOne() {
            var carry: UInt32 = 0
            for i in limbs.indices {
                let next = limbs[i] >> 31
                limbs[i] = limbs[i] << 1 | carry
                carry = next
            }
        }

        mutating func add(_ o: Num) {
            var carry: UInt64 = 0
            for i in limbs.indices {
                let s = UInt64(limbs[i]) + UInt64(o.limbs[i]) + carry
                limbs[i] = UInt32(truncatingIfNeeded: s)
                carry = s >> 32
            }
        }

        mutating func subtract(_ o: Num) {
            var borrow: Int64 = 0
            for i in limbs.indices {
                var d = Int64(limbs[i]) - Int64(o.limbs[i]) - borrow
                borrow = 0
                if d < 0 { d += 1 << 32; borrow = 1 }
                limbs[i] = UInt32(d)
            }
        }

        static func < (a: Num, b: Num) -> Bool {
            for i in a.limbs.indices.reversed() where a.limbs[i] != b.limbs[i] { return a.limbs[i] < b.limbs[i] }
            return false
        }
    }
}
