import Foundation
import Synchronization

/// Races the phone's paths (ADR-0002): P1 LAN UDP, P2 home UDP, P3 WSS 443, started with a 150 ms stagger.
///
/// - Until a path hears from the Mac, every started path carries every packet (the handshake goes out on
///   all of them; duplicates die in the Noise replay window).
/// - The best-ranked path that has delivered a packet becomes active and carries traffic alone. Every 2 s
///   a packet is also copied to better-ranked paths; when one answers it takes over (UDP after WSS).
/// - An active path that hears nothing for 400 ms while we keep sending (pings run at 10 Hz) is dropped,
///   and traffic goes out on all paths again until one answers: UDP blocked mid-stream → WSS in < 1 s.
/// - A dead path (socket error, closed WebSocket) is rebuilt every 2 s.
/// - `add(_:)` joins a path mid-session (the Mac turns up on this Wi-Fi after connecting by address); when it
///   ranks better, the 2 s probes find it and traffic moves there without a new handshake.
public final class PathRacer: PacketPath {
    public struct Candidate: Sendable {
        public let rank: Int
        public let delay: Duration
        public let make: @Sendable () -> any PacketPath
        public init(rank: Int, delay: Duration, make: @escaping @Sendable () -> any PacketPath) {
            self.rank = rank; self.delay = delay; self.make = make
        }
    }

    private struct Slot {
        let id: Int
        let candidate: Candidate
        var path: (any PacketPath)?
        var up = false
        var lastInbound: ContinuousClock.Instant?
        var lastRetry: ContinuousClock.Instant?
    }

    private struct State {
        var slots: [Slot]
        var nextId: Int
        var started = false
        var active: Int?
        var lastProbe = ContinuousClock.now
        var lastSend: ContinuousClock.Instant?
        var stopped = false
        var switches = 0
    }

    public let name = "race"
    private let state: Mutex<State>
    public let datagrams: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let silenceLimit: Duration
    private let housekeeping = Mutex<Task<Void, Never>?>(nil)

    public init(_ candidates: [Candidate], silenceLimit: Duration = .milliseconds(400)) {
        self.silenceLimit = silenceLimit
        let sorted = candidates.sorted { $0.rank < $1.rank }
        state = Mutex(State(slots: sorted.enumerated().map { Slot(id: $0.offset, candidate: $0.element) }, nextId: sorted.count))
        (datagrams, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(1024))
    }

    /// The active path's name ("lan", "udp", "wss"), or nil while racing.
    public var activeName: String? { state.withLock { s in s.active.flatMap { s.slots[$0].path?.name } } }
    public var switches: Int { state.withLock { $0.switches } }
    /// The paths' names, best rank first (started or not).
    public var pathNames: [String] { state.withLock { $0.slots.map { $0.path?.name ?? "rank \($0.candidate.rank)" } } }

    /// Adds a path after the race started; it launches after its delay and is probed like the others.
    public func add(_ candidate: Candidate) {
        let (id, launchNow): (Int, Bool) = state.withLock { s in
            let id = s.nextId
            s.nextId += 1
            let at = s.slots.firstIndex { $0.candidate.rank > candidate.rank } ?? s.slots.count
            s.slots.insert(Slot(id: id, candidate: candidate, lastRetry: .now), at: at)
            if let a = s.active, a >= at { s.active = a + 1 }
            return (id, s.started && !s.stopped)
        }
        guard launchNow else { return }
        Task { [weak self] in
            try? await Task.sleep(for: candidate.delay)
            _ = await self?.launch(id)
        }
    }

    private static func index(_ id: Int, in s: State) -> Int? { s.slots.firstIndex { $0.id == id } }

    /// Returns once the first path is up (or throws when every path failed to start).
    public func start() async throws {
        let first = Mutex<CheckedContinuation<Void, Error>?>(nil)
        let failures = Atomic<Int>(0)
        let initial = state.withLock { s in s.started = true; return s.slots.map { ($0.id, $0.candidate.delay) } }
        let total = initial.count
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            first.withLock { $0 = k }
            if total == 0 { first.withLock { $0?.resume(throwing: TransportError.connectionFailed("no path to the Mac")); $0 = nil } }
            for (id, delay) in initial {
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    guard let self else { return }
                    if await self.launch(id) {
                        first.withLock { $0?.resume(); $0 = nil }
                    } else if failures.add(1, ordering: .relaxed).newValue == total {
                        first.withLock { $0?.resume(throwing: TransportError.connectionFailed("no path to the Mac")); $0 = nil }
                    }
                }
            }
        }
        let t = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.maintain()
            }
        }
        housekeeping.withLock { $0 = t }
    }

    /// Starts the path in slot `id`; true if it came up.
    private func launch(_ id: Int) async -> Bool {
        let made: (any PacketPath)? = state.withLock { s in
            guard !s.stopped, let i = Self.index(id, in: s), s.slots[i].path == nil else { return nil }
            let p = s.slots[i].candidate.make()
            s.slots[i].path = p
            s.slots[i].lastRetry = .now
            return p
        }
        guard let p = made else { return false }
        do { try await p.start() } catch {
            state.withLock { s in if let i = Self.index(id, in: s), s.slots[i].path === p { s.slots[i].path = nil } }
            return false
        }
        guard state.withLock({ s -> Bool in
            guard !s.stopped, let i = Self.index(id, in: s), s.slots[i].path === p else { return false }
            s.slots[i].up = true
            // A better path than the active one just came up: probe it on the next send rather than up to 2 s
            // later. That first packet on a new flow often loses to its copy on the active path; the next one wins.
            if let a = s.active, i < a { s.lastProbe = .now - .seconds(3) }
            return true
        }) else { p.stop(); return false }
        Task { [weak self] in
            for await d in p.datagrams { self?.inbound(id, d) }
            self?.down(id, p)
        }
        return true
    }

    private func inbound(_ id: Int, _ d: [UInt8]) {
        state.withLock { s in
            guard let i = Self.index(id, in: s) else { return }
            s.slots[i].lastInbound = .now
            if s.active.map({ i < $0 }) ?? true {
                if s.active != nil { s.switches += 1 }
                s.active = i
            }
        }
        continuation.yield(d)
    }

    private func down(_ id: Int, _ p: any PacketPath) {
        state.withLock { s in
            guard let i = Self.index(id, in: s), s.slots[i].path === p else { return }
            s.slots[i].path = nil
            s.slots[i].up = false
            s.slots[i].lastInbound = nil
            s.slots[i].lastRetry = .now
            if s.active == i { s.active = nil }
        }
    }

    public func send(_ packets: [[UInt8]]) {
        let now = ContinuousClock.now
        let targets: [any PacketPath] = state.withLock { s in
            s.lastSend = now
            let up = s.slots.indices.filter { s.slots[$0].up }
            guard let a = s.active else { return up.compactMap { s.slots[$0].path } }
            var t = [s.slots[a].path].compactMap { $0 }
            if a > 0, now - s.lastProbe > .seconds(2) {               // probe the better paths
                s.lastProbe = now
                // Better paths first: the Mac takes whichever copy lands first and drops the other as a replay,
                // so the probe only counts if it beats the active path's copy.
                t = up.filter { $0 < a }.compactMap { s.slots[$0].path } + t
            }
            return t
        }
        for p in targets { p.send(packets) }
    }

    private func maintain() async {
        let now = ContinuousClock.now
        let retry: [Int] = state.withLock { s -> [Int] in
            if let a = s.active, let sent = s.lastSend, now - sent < .milliseconds(150),
               let heard = s.slots[a].lastInbound, now - heard > silenceLimit {
                s.active = nil                                         // gone quiet: race again
                s.switches += 1
            }
            return s.slots.filter { $0.path == nil && ($0.lastRetry.map { now - $0 > .seconds(2) } ?? true) }.map(\.id)
        }
        for i in retry { Task { [weak self] in _ = await self?.launch(i) } }
    }

    public func stop() {
        let paths = state.withLock { s -> [any PacketPath] in
            s.stopped = true
            return s.slots.compactMap(\.path)
        }
        housekeeping.withLock { $0?.cancel() }
        paths.forEach { $0.stop() }
        continuation.finish()
    }
}
