/// Harness A (docs/video.md §2): the Mac draws an 8×8 black/white cell patch in a screen corner,
/// encoding the frame counter and the Mac's monotonic time. The phone reads the patch back from the
/// decoded picture and logs `presentTime − macTime` (corrected by `ClockSync`).
///
/// Layout, 64 bits, MSB first, row-major: `seq(24) | macTimeMicros mod 2^32 (32) | crc8(8)`.
public enum BarcodePatch {
    public static let cells = 8
    public static let bitCount = 64

    public struct Value: Equatable, Sendable {
        public var sequence: UInt32       // low 24 bits used
        public var timeMicros: UInt32     // Mac monotonic µs mod 2^32
        public init(sequence: UInt32, timeMicros: UInt32) {
            self.sequence = sequence & 0xFF_FFFF
            self.timeMicros = timeMicros
        }
    }

    public static func encode(_ v: Value) -> [Bool] {
        let body = UInt64(v.sequence & 0xFF_FFFF) << 32 | UInt64(v.timeMicros)
        let word = body << 8 | UInt64(crc8(body))
        return (0..<bitCount).map { word >> UInt64(bitCount - 1 - $0) & 1 == 1 }
    }

    /// `cells` must hold 64 values (true = white). Returns nil if the checksum fails, e.g. when the
    /// sampled frame was mid-update or blurred by compression.
    public static func decode(_ cells: [Bool]) -> Value? {
        guard cells.count == bitCount else { return nil }
        var word: UInt64 = 0
        for b in cells { word = word << 1 | (b ? 1 : 0) }
        let body = word >> 8
        guard UInt8(truncatingIfNeeded: word) == crc8(body) else { return nil }
        return Value(sequence: UInt32(truncatingIfNeeded: body >> 32), timeMicros: UInt32(truncatingIfNeeded: body))
    }

    /// CRC-8/ATM (poly 0x07) over the 7 body bytes.
    static func crc8(_ body: UInt64) -> UInt8 {
        var crc: UInt8 = 0
        for shift in stride(from: 48, through: 0, by: -8) {
            crc ^= UInt8(truncatingIfNeeded: body >> UInt64(shift))
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc << 1) ^ 0x07 : crc << 1 }
        }
        return crc
    }

    /// Recovers the full time from a 32-bit µs value using a nearby full reference (handles wrap).
    public static func unwrapMicros(_ low: UInt32, near reference: UInt64) -> UInt64 {
        let period: UInt64 = 1 << 32
        let base = reference & ~(period - 1)
        let candidates = [base &- period, base, base &+ period].map { $0 | UInt64(low) }
        return candidates.min { a, b in
            (a > reference ? a - reference : reference - a) < (b > reference ? b - reference : reference - b)
        } ?? (base | UInt64(low))
    }
}

/// NTP-style clock offset between the phone and the Mac from Ping/Pong samples.
/// Keeps the sample with the smallest round-trip delay among the recent ones (least queuing noise).
public struct ClockSync: Sendable {
    public struct Sample: Sendable, Equatable {
        /// Remote clock minus local clock, nanoseconds.
        public let offsetNs: Int64
        public let delayNs: Int64
    }

    private var samples: [Sample] = []
    public let window: Int

    public init(window: Int = 32) { self.window = window }

    /// t1 local send, t2 remote receive, t3 remote send, t4 local receive (all ns).
    @discardableResult
    public mutating func add(t1: UInt64, t2: UInt64, t3: UInt64, t4: UInt64) -> Sample? {
        guard t4 >= t1, t3 >= t2 else { return nil }
        let a = Int64(bitPattern: t2 &- t1)
        let b = Int64(bitPattern: t3 &- t4)
        let offset = a / 2 + b / 2
        let delay = Int64(bitPattern: (t4 - t1) &- (t3 - t2))
        guard delay >= 0 else { return nil }
        let s = Sample(offsetNs: offset, delayNs: delay)
        samples.append(s)
        if samples.count > window { samples.removeFirst(samples.count - window) }
        return s
    }

    public var best: Sample? { samples.min { $0.delayNs < $1.delayNs } }

    /// Converts a remote timestamp into the local clock.
    public func toLocal(remoteNs: UInt64) -> UInt64? {
        guard let best else { return nil }
        return UInt64(bitPattern: Int64(bitPattern: remoteNs) &- best.offsetNs)
    }
}

/// Rolling latency percentiles for the HUD and bench reports.
public struct LatencyStats: Sendable {
    private var values: [Double] = []
    private var next = 0
    public let capacity: Int

    public init(capacity: Int = 600) { self.capacity = capacity }

    public mutating func add(_ ms: Double) {
        guard ms.isFinite else { return }
        if values.count < capacity {
            values.append(ms)
        } else {
            values[next] = ms
            next = (next + 1) % capacity
        }
    }

    public var count: Int { values.count }

    public func percentile(_ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = min(sorted.count - 1, max(0, Int((p / 100 * Double(sorted.count - 1)).rounded())))
        return sorted[rank]
    }

    public var p50: Double? { percentile(50) }
    public var p95: Double? { percentile(95) }
}
