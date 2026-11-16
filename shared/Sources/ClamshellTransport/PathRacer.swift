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
        var path: (any PacketPath)?
        var up = false
        var lastInbound: ContinuousClock.Instant?
        var lastRetry: ContinuousClock.Instant?
    }

    private struct State {
        var slots: [Slot]
        var active: Int?
        var lastProbe = ContinuousClock.now
        var lastSend: ContinuousClock.Instant?
        var stopped = false
        var switches = 0
    }

    public let name = "race"
    private let candidates: [Candidate]
    private let state: Mutex<State>
    public let datagrams: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let silenceLimit: Duration
    private let housekeeping = Mutex<Task<Void, Never>?>(nil)

    public init(_ candidates: [Candidate], silenceLimit: Duration = .milliseconds(400)) {
        self.candidates = candidates.sorted { $0.rank < $1.rank }
        self.silenceLimit = silenceLimit
        state = Mutex(State(slots: Array(repeating: Slot(), count: candidates.count)))
        (datagrams, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(1024))
    }

    /// The active path's name ("lan", "udp", "wss"), or nil while racing.
    public var activeName: String? { state.withLock { s in s.active.flatMap { s.slots[$0].path?.name } } }
    public var switches: Int { state.withLock { $0.switches } }

    /// Returns once the first path is up (or throws when every path failed to start).
    public func start() async throws {
        let first = Mutex<CheckedContinuation<Void, Error>?>(nil)
        let failures = Atomic<Int>(0)
        let total = candidates.count
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            first.withLock { $0 = k }
            for i in candidates.indices {
                Task { [weak self] in
                    try? await Task.sleep(for: self?.candidates[i].delay ?? .zero)
                    guard let self else { return }
                    if await self.launch(i) {
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

    /// Starts candidate `i`; true if it came up.
    private func launch(_ i: Int) async -> Bool {
        guard !state.withLock({ $0.stopped }) else { return false }
        let p = candidates[i].make()
        state.withLock { $0.slots[i].path = p; $0.slots[i].lastRetry = .now }
        do { try await p.start() } catch {
            state.withLock { if $0.slots[i].path === p { $0.slots[i].path = nil } }
            return false
        }
        guard state.withLock({ s -> Bool in
            guard !s.stopped, s.slots[i].path === p else { return false }
            s.slots[i].up = true
            return true
        }) else { p.stop(); return false }
        Task { [weak self] in
            for await d in p.datagrams { self?.inbound(i, d) }
            self?.down(i, p)
        }
        return true
    }

    private func inbound(_ i: Int, _ d: [UInt8]) {
        state.withLock { s in
            s.slots[i].lastInbound = .now
            if s.active.map({ i < $0 }) ?? true {
                if s.active != nil { s.switches += 1 }
                s.active = i
            }
        }
        continuation.yield(d)
    }

    private func down(_ i: Int, _ p: any PacketPath) {
        state.withLock { s in
            guard s.slots[i].path === p else { return }
            s.slots[i] = Slot(path: nil, up: false, lastInbound: nil, lastRetry: .now)
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
                t += up.filter { $0 < a }.compactMap { s.slots[$0].path }
            }
            return t
        }
        for p in targets { p.send(packets) }
    }

    private func maintain() async {
        let now = ContinuousClock.now
        let retry: [Int] = state.withLock { s in
            if let a = s.active, let sent = s.lastSend, now - sent < .milliseconds(150),
               let heard = s.slots[a].lastInbound, now - heard > silenceLimit {
                s.active = nil                                         // gone quiet: race again
                s.switches += 1
            }
            return s.slots.indices.filter { s.slots[$0].path == nil && (s.slots[$0].lastRetry.map { now - $0 > .seconds(2) } ?? true) }
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
