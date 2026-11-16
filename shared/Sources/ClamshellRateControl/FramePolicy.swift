import Synchronization

/// A one-item mailbox between pipeline stages (ADR-0008 §1: "never queue").
/// `put` replaces whatever is waiting and counts the replaced item as dropped.
public final class LatestSlot<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var dropped = 0
        var delivered = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Returns true if an older value was replaced (dropped).
    @discardableResult
    public func put(_ value: Value) -> Bool {
        state.withLock { s in
            let replaced = s.value != nil
            if replaced { s.dropped += 1 }
            s.value = value
            return replaced
        }
    }

    public func take() -> Value? {
        state.withLock { s in
            guard let v = s.value else { return nil }
            s.value = nil
            s.delivered += 1
            return v
        }
    }

    public var droppedCount: Int { state.withLock { $0.dropped } }
    public var deliveredCount: Int { state.withLock { $0.delivered } }
}

/// What the encoder should do on a tick when the screen didn't change.
public enum RefinementAction: Equatable, Sendable {
    /// Re-encode the last picture as a P-frame capped at this QP.
    case refine(maxQP: Int)
}

/// Schedules the refinement re-encodes that make static text sharp (ADR-0008 §3):
/// QP≈18 after 120 ms of stillness, QP≈12 after 400 ms, then nothing until content changes.
public struct RefinementScheduler: Sendable {
    public struct Stage: Sendable, Equatable {
        public var delay: Duration
        public var maxQP: Int
        public init(delay: Duration, maxQP: Int) { self.delay = delay; self.maxQP = maxQP }
    }

    public static let defaultStages = [Stage(delay: .milliseconds(120), maxQP: 18), Stage(delay: .milliseconds(400), maxQP: 12)]

    public let stages: [Stage]
    private var lastChange: ContinuousClock.Instant?
    private var nextStage = 0
    private var retryAfter: ContinuousClock.Instant?
    private var retries = 0
    /// Retries of dropped refinements per still period (the encoder drops frames when its rate budget is
    /// spent, typically right after a scroll; measured in M1 harness D).
    public static let maxRetries = 12

    public init(stages: [Stage] = RefinementScheduler.defaultStages) {
        self.stages = stages.sorted { $0.delay < $1.delay }
    }

    /// Call when a frame with real damage was encoded.
    public mutating func contentChanged(at t: ContinuousClock.Instant) {
        lastChange = t
        nextStage = 0
        retryAfter = nil
        retries = 0
    }

    /// Call when the encoder dropped (or failed) the refinement `poll` asked for: the same stage is
    /// offered again after `backoff`, up to `maxRetries` times per still period.
    public mutating func refinementDropped(at t: ContinuousClock.Instant, backoff: Duration = .milliseconds(20)) {
        guard nextStage > 0, retries < Self.maxRetries else { return }
        retries += 1
        nextStage -= 1
        retryAfter = t + backoff
    }

    /// Call on each idle tick. Returns at most one action per stage per still period.
    public mutating func poll(now: ContinuousClock.Instant) -> RefinementAction? {
        guard let lastChange, nextStage < stages.count else { return nil }
        if let retryAfter, now < retryAfter { return nil }
        // If several stages are overdue (e.g. a long encoder stall), skip to the latest one.
        var due: Int?
        for i in nextStage..<stages.count where now - lastChange >= stages[i].delay { due = i }
        guard let due else { return nil }
        nextStage = due + 1
        retryAfter = nil
        return .refine(maxQP: stages[due].maxQP)
    }

    public var nextDeadline: ContinuousClock.Instant? {
        guard let lastChange, nextStage < stages.count else { return nil }
        let due = lastChange + stages[nextStage].delay
        return retryAfter.map { max($0, due) } ?? due
    }
}
