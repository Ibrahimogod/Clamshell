import ClamshellWire

/// Splits an encoded frame into `VideoFragment`s that each fit one datagram.
public struct Fragmenter: Sendable {
    public let maxFragmentPayload: Int

    public init(maxFragmentPayload: Int) {
        precondition(maxFragmentPayload > 0, "fragment payload budget must be positive")
        self.maxFragmentPayload = maxFragmentPayload
    }

    /// Payload budget for one fragment given a datagram size and the session's per-packet overhead.
    /// Inner header worst case: channel 1 + type 2 + flags 1 + varint length 3.
    public static func payloadBudget(datagram: Int, sessionOverhead: Int) -> Int {
        datagram - sessionOverhead - 7 - VideoFragment.headerSize
    }

    public enum FragmentError: Error, Equatable { case frameTooLarge(Int) }

    /// - Parameter parityGroup: 0 for no FEC; otherwise one XOR parity fragment follows every `parityGroup`
    ///   data fragments (the last group may be shorter), so any single loss in a group can be rebuilt.
    ///   Parity payloads are 3 bytes longer than data ones, so the budget leaves room for them.
    public func fragments(frameId: UInt32, flags: VideoFrameFlags, formatGeneration: UInt16,
                          captureTimeNs: UInt64, data: [UInt8], parityGroup: Int = 0) throws -> [VideoFragment] {
        let budget = parityGroup > 0 ? maxFragmentPayload - Parity.headerSize : maxFragmentPayload
        let count = max(1, (data.count + budget - 1) / budget)
        guard count <= Int(UInt16.max) else { throw FragmentError.frameTooLarge(data.count) }
        var out: [VideoFragment] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let start = i * budget
            let end = min(data.count, start + budget)
            out.append(VideoFragment(frameId: frameId, index: UInt16(i), count: UInt16(count), flags: flags,
                                     formatGeneration: formatGeneration, captureTimeNs: captureTimeNs,
                                     payload: Array(data[start..<end])))
        }
        guard parityGroup > 0 else { return out }
        let group = min(parityGroup, Int(UInt8.max))
        for g in stride(from: 0, to: count, by: group) {
            let members = out[g..<min(count, g + group)].map(\.payload)
            out.append(VideoFragment(frameId: frameId, index: UInt16(g / group), count: UInt16(count), flags: flags.union(.parity),
                                     formatGeneration: formatGeneration, captureTimeNs: captureTimeNs,
                                     payload: Parity.make(members, groupSize: group)))
        }
        return out
    }
}

/// XOR parity over a group of fragment payloads (`VideoFrameFlags.parity`).
public enum Parity {
    public static let headerSize = 3

    static func make(_ payloads: [[UInt8]], groupSize: Int) -> [UInt8] {
        let width = payloads.map(\.count).max() ?? 0
        var lengths: UInt16 = 0
        var x = [UInt8](repeating: 0, count: width)
        for p in payloads {
            lengths ^= UInt16(truncatingIfNeeded: p.count)
            for (i, b) in p.enumerated() { x[i] ^= b }
        }
        return [UInt8(groupSize), UInt8(lengths >> 8), UInt8(lengths & 0xFF)] + x
    }

    /// The one missing payload of a group, from its parity and the others. Nil if the parity is malformed.
    static func recover(parity: [UInt8], others: [[UInt8]]) -> [UInt8]? {
        guard parity.count >= headerSize else { return nil }
        var length = UInt16(parity[1]) << 8 | UInt16(parity[2])
        var x = Array(parity[headerSize...])
        for p in others {
            length ^= UInt16(truncatingIfNeeded: p.count)
            guard p.count <= x.count else { return nil }
            for (i, b) in p.enumerated() { x[i] ^= b }
        }
        guard Int(length) <= x.count else { return nil }
        return Array(x[..<Int(length)])
    }

    static func groupSize(of parity: [UInt8]) -> Int? {
        guard let g = parity.first, g > 0 else { return nil }
        return Int(g)
    }
}

/// Client-side reassembly with the "never queue" rule (ADR-0008 §1):
/// - when a frame completes, every older incomplete frame is discarded (reported as lost);
/// - fragments of frames at or before the last completed one are ignored;
/// - an incomplete frame that sees no fragment for `timeout` is dropped;
/// - with FEC, a group missing exactly one data fragment is rebuilt from its parity fragment.
/// A gap in frame ids means the reference chain is broken: the caller requests a keyframe unless
/// the completed frame is itself a keyframe.
public struct Reassembler: Sendable {
    public struct Frame: Sendable, Equatable {
        public let frameId: UInt32
        public let flags: VideoFrameFlags
        public let formatGeneration: UInt16
        public let captureTimeNs: UInt64
        public let data: [UInt8]
    }

    public enum Event: Sendable, Equatable {
        case complete(Frame, precededByGap: Bool)
        case dropped(frameId: UInt32)
    }

    /// Running totals, for `ReceiverReport` (the client sends the change per interval).
    public struct Counters: Sendable, Equatable {
        /// Data fragments that arrived for frames now finished (completed or dropped), and how many those frames had.
        public var fragmentsReceived = 0
        public var fragmentsExpected = 0
        public var fecRecovered = 0
        /// Frame ids that were never completed: dropped, plus ids skipped entirely.
        public var framesLost = 0
        public var framesCompleted = 0
        public var bytesReceived = 0
        public init() {}
    }

    private struct Pending {
        var flags: VideoFrameFlags
        var formatGeneration: UInt16
        var captureTimeNs: UInt64
        var parts: [[UInt8]?]
        var arrived: Int          // data fragments that arrived (not rebuilt)
        var received: Int         // arrived + rebuilt
        var bytes: Int
        var parity: [Int: [UInt8]] = [:]
        var lastArrival: ContinuousClock.Instant
    }

    public let maxFrameBytes: Int
    public let maxPendingFrames: Int
    public let timeout: Duration

    private var pending: [UInt32: Pending] = [:]
    /// Gap baseline: the last completed frame, forgotten when the chain restarts at a keyframe.
    private var lastCompleted: UInt32?
    /// Fragments of frames at or below this id are late (duplicates, trailing parity): always ignored,
    /// even after `resetChain`.
    private var floor: UInt32?
    private var highestSeen: UInt32?
    public private(set) var counters = Counters()
    public var completedCount: Int { counters.framesCompleted }
    public private(set) var droppedCount = 0
    public var highestFrameId: UInt32 { highestSeen ?? 0 }

    public init(maxFrameBytes: Int = 8 * 1024 * 1024, maxPendingFrames: Int = 4, timeout: Duration = .milliseconds(250)) {
        self.maxFrameBytes = maxFrameBytes
        self.maxPendingFrames = maxPendingFrames
        self.timeout = timeout
    }

    public mutating func add(_ f: VideoFragment, now: ContinuousClock.Instant) -> [Event] {
        if let floor, f.frameId <= floor { return [] }
        counters.bytesReceived += f.payload.count
        highestSeen = max(highestSeen ?? f.frameId, f.frameId)
        var events: [Event] = []
        let isParity = f.flags.contains(.parity)
        var p = pending[f.frameId] ?? Pending(flags: f.flags.subtracting(.parity), formatGeneration: f.formatGeneration,
                                              captureTimeNs: f.captureTimeNs, parts: Array(repeating: nil, count: Int(f.count)),
                                              arrived: 0, received: 0, bytes: 0, lastArrival: now)
        guard p.parts.count == Int(f.count), isParity || Int(f.index) < p.parts.count else {
            // Inconsistent fragment count for this frame: treat the frame as corrupt.
            if let bad = pending.removeValue(forKey: f.frameId) { finish(bad) }
            drop(f.frameId, into: &events)
            return events
        }
        p.lastArrival = now
        if isParity {
            if p.parity[Int(f.index)] == nil { p.parity[Int(f.index)] = f.payload }
        } else if p.parts[Int(f.index)] == nil {
            p.parts[Int(f.index)] = f.payload
            p.arrived += 1
            p.received += 1
            p.bytes += f.payload.count
        }
        rebuild(&p)
        guard p.bytes <= maxFrameBytes else {
            pending[f.frameId] = nil
            finish(p)
            drop(f.frameId, into: &events)
            return events
        }

        if p.received == p.parts.count {
            pending[f.frameId] = nil
            for id in pending.keys.sorted() where id < f.frameId {
                if let old = pending.removeValue(forKey: id) { finish(old) }
                drop(id, into: &events)
            }
            let gap = lastCompleted.map { f.frameId != $0 &+ 1 } ?? false
            if let last = lastCompleted, f.frameId > last &+ 1 {
                // Ids in the gap that never showed up at all (dropped ones are already counted).
                let skipped = Int(f.frameId - last - 1) - events.count
                counters.framesLost += max(0, skipped)
            }
            lastCompleted = f.frameId
            floor = f.frameId
            counters.framesCompleted += 1
            finish(p)
            var data: [UInt8] = []
            data.reserveCapacity(p.bytes)
            for part in p.parts { if let part { data += part } }
            events.append(.complete(Frame(frameId: f.frameId, flags: p.flags, formatGeneration: p.formatGeneration,
                                          captureTimeNs: p.captureTimeNs, data: data), precededByGap: gap))
        } else {
            pending[f.frameId] = p
            // Bound memory: keep only the newest `maxPendingFrames` incomplete frames.
            while pending.count > maxPendingFrames, let oldest = pending.keys.min() {
                if let old = pending.removeValue(forKey: oldest) { finish(old) }
                drop(oldest, into: &events)
            }
        }
        return events
    }

    /// Drops incomplete frames that stopped receiving fragments.
    public mutating func expire(now: ContinuousClock.Instant) -> [Event] {
        var events: [Event] = []
        for id in pending.keys.sorted() {
            guard let p = pending[id], now - p.lastArrival >= timeout else { continue }
            pending[id] = nil
            finish(p)
            drop(id, into: &events)
        }
        return events
    }

    /// After a keyframe the chain restarts; forget the gap baseline (late fragments stay ignored).
    public mutating func resetChain() { lastCompleted = nil }

    private mutating func drop(_ id: UInt32, into events: inout [Event]) {
        droppedCount += 1
        counters.framesLost += 1
        events.append(.dropped(frameId: id))
    }

    private mutating func finish(_ p: Pending) {
        counters.fragmentsReceived += p.arrived
        counters.fragmentsExpected += p.parts.count
    }

    /// Rebuilds every group that has its parity and exactly one data fragment missing.
    private mutating func rebuild(_ p: inout Pending) {
        guard !p.parity.isEmpty, p.received < p.parts.count else { return }
        for (g, parity) in p.parity {
            guard let size = Parity.groupSize(of: parity) else { continue }
            let range = (g * size)..<min(p.parts.count, (g + 1) * size)
            guard !range.isEmpty else { continue }
            let missing = range.filter { p.parts[$0] == nil }
            guard missing.count == 1, let hole = missing.first,
                  let payload = Parity.recover(parity: parity, others: range.compactMap { p.parts[$0] }) else { continue }
            p.parts[hole] = payload
            p.received += 1
            p.bytes += payload.count
            counters.fecRecovered += 1
        }
    }
}
