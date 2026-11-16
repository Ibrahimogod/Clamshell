/// Harness B on one device (docs/video.md §2): the Mac flips a square black ↔ white on its own panel and on the
/// streamed display at the same moment. The phone's rear camera watches the Mac panel while its screen
/// presents the stream. Both sides become flip times on the phone's clock, and the lag between matching flips
/// is glass-to-glass latency. Pure logic, so it's unit-tested. Camera and renderer feed it samples.

/// A brightness flip: when the level crossed the threshold, and in which direction.
public struct FlashEdge: Equatable, Sendable {
    public var timeNs: UInt64
    public var rising: Bool
    public init(timeNs: UInt64, rising: Bool) {
        self.timeNs = timeNs
        self.rising = rising
    }
}

/// Turns a stream of (time, level) samples into flips. The threshold is fixed (renderer: luma 128) or learned
/// from the levels seen so far (camera: midpoint of the darkest and brightest level, once they're at least
/// `minimumSwing` apart).
///
/// A flip only counts once the level is `hysteresis` × swing past the threshold for `confirmSamples` samples
/// in a row, so a level hovering at the threshold (a rolling-shutter frame caught mid-flip, sensor noise)
/// can't fire extra edges. Without this, extra camera edges paired with the wrong screen flip.
///
/// A camera integrates light over its exposure, so its crossing time is interpolated at the threshold
/// between the last sample on the old side and the first on the new side. Decoded pictures are discrete and
/// only arrive when something changed (damage skip), so the renderer uses `interpolates: false`: the flip is
/// the time of the first picture that confirms it.
public struct FlashEdgeDetector: Sendable {
    public let fixedThreshold: Double?
    public let minimumSwing: Double
    public let interpolates: Bool
    public let hysteresis: Double
    public let confirmSamples: Int
    private var recent: [(timeNs: UInt64, level: Double)] = []      // newest last
    private var above: Bool?
    private var confirming = 0
    private var low = Double.greatestFiniteMagnitude
    private var high = -Double.greatestFiniteMagnitude

    public init(fixedThreshold: Double? = nil, minimumSwing: Double = 40, interpolates: Bool = true,
                hysteresis: Double = 0.2, confirmSamples: Int = 1) {
        self.fixedThreshold = fixedThreshold
        self.minimumSwing = minimumSwing
        self.interpolates = interpolates
        self.hysteresis = hysteresis
        self.confirmSamples = max(1, confirmSamples)
    }

    public var threshold: Double? {
        if let fixedThreshold { return fixedThreshold }
        return high - low >= minimumSwing ? (low + high) / 2 : nil
    }

    /// Adds one sample. Returns the flip it completes, if any.
    public mutating func add(timeNs: UInt64, level: Double) -> FlashEdge? {
        if let last = recent.last, timeNs <= last.timeNs { return nil }
        low = min(low, level)
        high = max(high, level)
        recent.append((timeNs, level))
        if recent.count > 16 { recent.removeFirst(recent.count - 16) }
        guard let thr = threshold else { return nil }
        guard let wasAbove = above else {
            above = level >= thr
            return nil
        }
        let margin = hysteresis * (high - low)
        let past = wasAbove ? level < thr - margin : level >= thr + margin
        guard past else { confirming = 0; return nil }
        confirming += 1
        guard confirming >= confirmSamples else { return nil }
        confirming = 0
        above = !wasAbove
        let first = recent[recent.count - confirmSamples]
        guard interpolates else { return FlashEdge(timeNs: first.timeNs, rising: !wasAbove) }
        // The latest step across the threshold itself, from the old side to the new.
        for k in stride(from: recent.count - 1, to: 0, by: -1) {
            let a = recent[k - 1], b = recent[k]
            guard (a.level >= thr) == wasAbove, (b.level >= thr) != wasAbove else { continue }
            let fraction = min(max((thr - a.level) / (b.level - a.level), 0), 1)
            return FlashEdge(timeNs: a.timeNs + UInt64((Double(b.timeNs - a.timeNs) * fraction).rounded()), rising: !wasAbove)
        }
        return FlashEdge(timeNs: first.timeNs, rising: !wasAbove)
    }
}

/// Pairs each reference flip (the Mac panel, seen by the camera) with the first later flip of the same direction
/// in the follower (the phone's own presentation), within `maxLagNs`. Either side may arrive first: camera
/// frames reach the app a few ms after exposure, so a follower is kept until its reference turns up.
public struct FlashMatcher: Sendable {
    public let maxLagNs: UInt64
    private var reference: [FlashEdge] = []
    private var pending: [FlashEdge] = []
    public private(set) var lagsMs: [Double] = []

    public init(maxLagNs: UInt64 = 350_000_000) { self.maxLagNs = maxLagNs }

    /// A reference flip. Returns a lag (ms) when it answers a follower that arrived before it.
    @discardableResult
    public mutating func addReference(_ e: FlashEdge) -> Double? {
        if let j = pending.firstIndex(where: { answers(ref: e, follower: $0) }) {
            let lag = record(ref: e, follower: pending[j])
            pending.removeSubrange(...j)
            return lag
        }
        reference.append(e)
        if reference.count > 64 { reference.removeFirst(reference.count - 64) }
        return nil
    }

    /// A follower flip. Returns its lag (ms) when it answers a reference flip seen already.
    @discardableResult
    public mutating func addFollower(_ e: FlashEdge) -> Double? {
        // The most recent unmatched reference flip of the same direction that precedes this one.
        guard let i = reference.lastIndex(where: { answers(ref: $0, follower: e) }) else {
            pending.append(e)
            if pending.count > 16 { pending.removeFirst(pending.count - 16) }
            return nil
        }
        let lag = record(ref: reference[i], follower: e)
        reference.removeSubrange(...i)
        return lag
    }

    private func answers(ref: FlashEdge, follower: FlashEdge) -> Bool {
        ref.rising == follower.rising && ref.timeNs <= follower.timeNs && follower.timeNs - ref.timeNs <= maxLagNs
    }

    private mutating func record(ref: FlashEdge, follower: FlashEdge) -> Double {
        let lag = Double(follower.timeNs - ref.timeNs) / 1e6
        lagsMs.append(lag)
        if lagsMs.count > 2000 { lagsMs.removeFirst(lagsMs.count - 2000) }
        return lag
    }
}

/// Finds the flashing square in the camera picture without aiming help: the picture is cut into a grid,
/// and the cell whose level flips between two steady values most strongly is chosen. A cell must swing by at
/// least `minimumSwing`, sit near one of its two extremes most of the time (rejects auto-exposure ramps and
/// moving edges) and cross its midpoint at least `minimumCrossings` times (rejects a hand passing once).
public struct FlashSpotFinder: Sendable {
    public let cellCount: Int
    public let minimumSwing: Double
    public let minimumCrossings: Int
    private var levels: [[Double]]

    public init(cellCount: Int, minimumSwing: Double = 40, minimumCrossings: Int = 4) {
        self.cellCount = cellCount
        self.minimumSwing = minimumSwing
        self.minimumCrossings = minimumCrossings
        levels = Array(repeating: [], count: cellCount)
    }

    public var frames: Int { levels.first?.count ?? 0 }

    /// One frame: the mean level of every cell, in row-major order.
    public mutating func add(_ cells: [Double]) {
        guard cells.count == cellCount else { return }
        for i in 0..<cellCount { levels[i].append(cells[i]) }
    }

    public mutating func reset() { levels = Array(repeating: [], count: cellCount) }

    /// The best cell so far, if any qualifies.
    public func best() -> Int? {
        var bestCell: Int?, bestScore = 0.0
        for (i, v) in levels.enumerated() {
            guard let lo = v.min(), let hi = v.max() else { continue }
            let swing = hi - lo
            guard swing >= minimumSwing else { continue }
            let mid = (lo + hi) / 2, band = swing / 4
            let steady = Double(v.count { $0 - lo <= band || hi - $0 <= band }) / Double(v.count)
            var crossings = 0
            for k in 1..<v.count where (v[k - 1] >= mid) != (v[k] >= mid) { crossings += 1 }
            guard steady >= 0.8, crossings >= minimumCrossings else { continue }
            let score = swing * steady
            if score > bestScore { bestScore = score; bestCell = i }
        }
        return bestCell
    }
}
