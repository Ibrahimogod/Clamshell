/// Rate control for paths we don't own (ADR-0008 §5): cellular, someone else's Wi-Fi, a home upload of a
/// few Mbit/s. The phone measures, the Mac decides. Pure logic, so it's unit-tested against traces.

/// Phone side: how much queuing delay the path is adding right now. Each completed frame gives
/// `arrival (phone clock) − capture (Mac clock)`, which is a constant clock offset plus the one-way delay.
/// The lowest value over the last `window` is the path's base delay. A rise above it is a queue building up
/// (a bottleneck about to drop packets), which shows before any loss does.
public struct DelayTracker: Sendable {
    public let windowNs: UInt64
    private var samples: [(atNs: UInt64, offsetNs: Int64)] = []
    private var smoothed: Double?

    public init(windowNs: UInt64 = 10_000_000_000) { self.windowNs = windowNs }

    public mutating func add(arrivalNs: UInt64, captureNs: UInt64) {
        let offset = Int64(bitPattern: arrivalNs &- captureNs)
        samples.append((arrivalNs, offset))
        if let first = samples.first, arrivalNs > windowNs, first.atNs < arrivalNs - windowNs {
            samples.removeAll { $0.atNs < arrivalNs - windowNs }
        }
        let base = samples.map(\.offsetNs).min() ?? offset
        let excess = Double(max(0, offset - base))
        smoothed = smoothed.map { $0 * 0.7 + excess * 0.3 } ?? excess
    }

    /// Smoothed delay above the window's minimum, in microseconds.
    public var queuingDelayMicros: UInt32 { UInt32(clamping: Int(((smoothed ?? 0) / 1000).rounded())) }
}

/// Mac side: picks the encoder bitrate and the FEC strength from `ReceiverReport`s.
///
/// - Queuing delay or heavy loss: back off multiplicatively, at most once per `backoffInterval`.
///   Thresholds leave room for jitter: busy Wi-Fi adds 10–25 ms of it with no queue at all, and cellular
///   much more, so delay counts only above the jitter learned while the sender was idle (`jitterMs`), and
///   not at all while the sender uses under half its target (a queue it can't be filling).
/// - Start-up (until the first backoff): +25% every half `increaseInterval`, so a LAN reaches the ceiling
///   from a cautious start in about 2 s, while a 4 Mbit/s hotel link is never hit with 20 Mbit/s.
/// - Then a clean path probes upward by 8% (at least 250 kbit/s) every `increaseInterval`, but only while the
///   sender actually uses most of the current target. A static screen sends almost nothing, and growing the
///   target then would only set up a burst the path can't take.
/// - FEC follows the loss that remains after FEC: off below 0.5%, then 1 parity per 10, 5 or 3 data fragments.
/// - Pacing: frames leave at up to 2.5 × the target, which keeps a frame's send time short. That is only
///   safe while the link is faster than that: on a 20 Mbit/s LTE downlink a 10 Mbit/s target already
///   overflows the buffer within every frame. So congestive loss (> 3%) caps the pacing rate at 85% of
///   what caused it, never below 1.15 × the target; the cap creeps back up 3% per clean second.
public struct BitrateController: Sendable {
    public struct Decision: Equatable, Sendable {
        public var bitrate: Int
        public var parityGroup: Int   // 0 = FEC off
        /// Bits per second the pacer may send at (≥ bitrate).
        public var pacingRate: Int
    }

    public static let pacingFactor = 2.5
    public static let minPacingFactor = 1.15

    public let minBitrate: Int
    public let maxBitrate: Int
    public let backoffIntervalNs: UInt64
    public let increaseIntervalNs: UInt64
    public private(set) var bitrate: Int
    public private(set) var parityGroup = 0
    private var lastBackoffNs: UInt64 = 0
    private var lastIncreaseNs: UInt64 = 0
    private var lossEWMA = 0.0
    private var cleanSinceNs: UInt64?
    public private(set) var inStartup = true
    public private(set) var pacingCap: Int?
    private var lastCapGrowNs: UInt64 = 0
    /// The path's own delay noise in ms: cellular scheduling adds 50–200 ms swings with no queue at all. It is
    /// learned while the Mac sends well under its target (so the delay can't be its own), at most 150 ms.
    public private(set) var jitterMs = 0.0

    public init(start: Int, min: Int = 1_000_000, max: Int, backoffIntervalNs: UInt64 = 300_000_000,
                increaseIntervalNs: UInt64 = 500_000_000) {
        minBitrate = min
        maxBitrate = Swift.max(min, max)
        bitrate = Swift.min(Swift.max(start, min), maxBitrate)
        self.backoffIntervalNs = backoffIntervalNs
        self.increaseIntervalNs = increaseIntervalNs
    }

    public var pacingRate: Int {
        let b = Double(bitrate)
        let wanted = b * Self.pacingFactor
        return Int(Swift.max(b * Self.minPacingFactor, Swift.min(wanted, pacingCap.map(Double.init) ?? wanted)))
    }

    public var decision: Decision { Decision(bitrate: bitrate, parityGroup: parityGroup, pacingRate: pacingRate) }

    /// - Parameters:
    ///   - loss: share of data fragments lost before FEC (0…1); `lostAfterFEC`: frames still lost after it.
    ///   - sentBitrate: what the Mac actually sent over the report's interval (bit/s).
    @discardableResult
    public mutating func update(nowNs: UInt64, loss: Double, framesLost: Int, queuingDelayMs: Double, sentBitrate: Int) -> Decision {
        lossEWMA = lossEWMA * 0.8 + loss * 0.2
        updateFEC(nowNs: nowNs)
        // Sending under half the target can't fill a queue: delay then is the path's noise, not congestion.
        let appLimited = Double(sentBitrate) < 0.5 * Double(bitrate)
        if appLimited, loss < 0.02 {
            let d = Swift.min(queuingDelayMs, 150)
            jitterMs += (d > jitterMs ? 0.2 : 0.05) * (d - jitterMs)
        }
        let queuingDelayMs = appLimited ? 0 : Swift.max(0, queuingDelayMs - jitterMs)

        let canBackOff = nowNs >= lastBackoffNs + backoffIntervalNs
        let interval = inStartup ? increaseIntervalNs / 2 : increaseIntervalNs
        let congestiveLoss = loss > 0.10 || (loss > 0.03 && framesLost > 0)
        if canBackOff, congestiveLoss {
            pacingCap = Int(Double(pacingRate) * 0.85)
            lastCapGrowNs = nowNs
        } else if let cap = pacingCap, loss < 0.02, queuingDelayMs < 20, nowNs >= lastCapGrowNs + 1_000_000_000 {
            pacingCap = cap + cap * 3 / 100
            lastCapGrowNs = nowNs
        }
        if canBackOff, loss > 0.10 || queuingDelayMs > 100 {
            backOff(0.7, nowNs: nowNs)
        } else if canBackOff, (loss > 0.03 && framesLost > 0) || queuingDelayMs > 40 {
            backOff(0.88, nowNs: nowNs)
        } else if queuingDelayMs < 20, loss < 0.02, nowNs >= lastIncreaseNs + interval,
                  nowNs >= lastBackoffNs + 2 * backoffIntervalNs, Double(sentBitrate) >= 0.6 * Double(bitrate) {
            let step = inStartup ? bitrate / 4 : bitrate * 8 / 100
            bitrate = Swift.min(maxBitrate, bitrate + Swift.max(250_000, step))
            lastIncreaseNs = nowNs
        }
        return decision
    }

    private mutating func backOff(_ factor: Double, nowNs: UInt64) {
        bitrate = Swift.max(minBitrate, Int(Double(bitrate) * factor))
        inStartup = false
        lastBackoffNs = nowNs
        lastIncreaseNs = nowNs
    }

    private mutating func updateFEC(nowNs: UInt64) {
        let wanted: Int
        switch lossEWMA {
        case ..<0.005: wanted = 0
        case ..<0.03: wanted = 10
        case ..<0.08: wanted = 5
        default: wanted = 3
        }
        if wanted == 0 {
            // Switch off only after 5 s of a clean path, so a bursty link doesn't flap.
            if parityGroup != 0 {
                if let since = cleanSinceNs {
                    if nowNs >= since + 5_000_000_000 { parityGroup = 0; cleanSinceNs = nil }
                } else {
                    cleanSinceNs = nowNs
                }
            }
        } else {
            cleanSinceNs = nil
            // Stronger right away; weaker only through the 5 s clean rule above.
            if parityGroup == 0 || wanted < parityGroup { parityGroup = wanted }
        }
    }
}

/// Spreads a frame's datagrams over time instead of one burst. Cellular schedulers and small home-router
/// buffers drop the tail of a 100-packet burst; pacing at `factor` × the target bitrate keeps the burst short
/// enough to add little latency (a 60 KB frame at 2.5 × 10 Mbit/s takes 19 ms), and lets a burst of
/// `burstBytes` go out at once.
public struct Pacer: Sendable {
    public var bitrate: Int
    /// Set per frame: keyframes go slower (they're 10–20× a delta frame, the burst most likely to overflow
    /// a small router buffer, and losing one costs a keyframe round trip).
    public var factor: Double
    public let burstBytes: Int
    private var budget: Double
    private var lastNs: UInt64?

    public init(bitrate: Int, factor: Double = 2.5, burstBytes: Int = 16 * 1200) {
        self.bitrate = bitrate
        self.factor = factor
        self.burstBytes = burstBytes
        budget = Double(burstBytes)
    }

    /// How long to wait before sending `bytes` (0 = now). Call `sent` after sending.
    public mutating func delayNs(for bytes: Int, nowNs: UInt64) -> UInt64 {
        refill(nowNs)
        guard budget < Double(bytes) else { return 0 }
        let rate = Double(bitrate) * factor / 8 / 1e9          // bytes per ns
        return UInt64(((Double(bytes) - budget) / rate).rounded(.up))
    }

    public mutating func sent(_ bytes: Int, nowNs: UInt64) {
        refill(nowNs)
        budget -= Double(bytes)
    }

    private mutating func refill(_ nowNs: UInt64) {
        defer { lastNs = nowNs }
        guard let last = lastNs, nowNs > last else { return }
        budget = min(Double(burstBytes), budget + Double(nowNs - last) * Double(bitrate) * factor / 8 / 1e9)
    }
}
