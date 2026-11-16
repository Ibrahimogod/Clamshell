import Testing
import ClamshellWire
@testable import ClamshellRateControl

/// FEC, receiver counters and the rate controller: what keeps the stream usable on cellular and other
/// people's Wi-Fi (ADR-0008 §5).
@Suite("FEC")
struct FECTests {
    func bytes(_ n: Int, seed: UInt8 = 0) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) } }
    let now = ContinuousClock.now

    func frags(_ size: Int, group: Int, id: UInt32 = 1) throws -> [VideoFragment] {
        try Fragmenter(maxFragmentPayload: 100).fragments(frameId: id, flags: [], formatGeneration: 1, captureTimeNs: 5,
                                                          data: bytes(size, seed: UInt8(truncatingIfNeeded: id)), parityGroup: group)
    }

    @Test func parityLayout() throws {
        let f = try frags(970, group: 4)                     // 97-byte budget → 10 data fragments, groups 4+4+2
        let data = f.filter { !$0.flags.contains(.parity) }, parity = f.filter { $0.flags.contains(.parity) }
        #expect(data.count == 10 && parity.count == 3)
        #expect(parity.map(\.index) == [0, 1, 2])
        #expect(f.allSatisfy { $0.payload.count <= 100 })
        #expect(parity.allSatisfy { $0.count == 10 })
    }

    @Test(arguments: 0..<10)
    func oneLossPerGroupIsRebuilt(_ lost: Int) throws {
        let f = try frags(950, group: 4)                     // last fragment is shorter: length is carried in parity
        var r = Reassembler()
        var events: [Reassembler.Event] = []
        for (i, x) in f.enumerated() where i != lost { events += r.add(x, now: now) }
        guard case .complete(let frame, _)? = events.last else { Issue.record("not completed"); return }
        #expect(frame.data == bytes(950, seed: 1))
        #expect(frame.flags == [])
        #expect(r.counters.fecRecovered == 1)
        #expect(r.counters.fragmentsReceived == 9 && r.counters.fragmentsExpected == 10)
    }

    @Test func parityFirstStillWorks() throws {
        let f = try frags(400, group: 5)
        var r = Reassembler()
        var events: [Reassembler.Event] = []
        for x in f.reversed().dropLast() { events += r.add(x, now: now) }   // fragment 0 lost, parity came first
        guard case .complete(let frame, _)? = events.last else { Issue.record("not completed"); return }
        #expect(frame.data == bytes(400, seed: 1))
    }

    @Test func twoLossesInAGroupAreNotRebuilt() throws {
        let f = try frags(970, group: 4)
        var r = Reassembler()
        var events: [Reassembler.Event] = []
        for (i, x) in f.enumerated() where i != 0 && i != 1 { events += r.add(x, now: now) }
        #expect(events.isEmpty)
        events = r.expire(now: now + .seconds(1))
        #expect(events == [.dropped(frameId: 1)])
        #expect(r.counters.framesLost == 1 && r.counters.fragmentsReceived == 8 && r.counters.fragmentsExpected == 10)
    }

    @Test func malformedParityIsIgnored() {
        #expect(Parity.recover(parity: [1, 0], others: []) == nil)
        #expect(Parity.recover(parity: [2, 0, 9, 1, 2], others: [[1]]) == nil)   // claims 9 bytes, has 2
        #expect(Parity.groupSize(of: [0, 0, 0]) == nil)
    }
}

@Suite("Receiver counters")
struct ReceiverCounterTests {
    let f = Fragmenter(maxFragmentPayload: 10)
    let now = ContinuousClock.now

    @Test func skippedIdsCountAsLost() throws {
        var r = Reassembler()
        _ = r.add(try f.fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [1])[0], now: now)
        _ = r.add(try f.fragments(frameId: 5, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [1])[0], now: now)
        #expect(r.counters.framesCompleted == 2)
        #expect(r.counters.framesLost == 3)
        #expect(r.highestFrameId == 5)
    }

    @Test func droppedAndSkippedAreNotDoubleCounted() throws {
        var r = Reassembler()
        _ = r.add(try f.fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [1])[0], now: now)
        _ = r.add(try f.fragments(frameId: 2, flags: [], formatGeneration: 0, captureTimeNs: 0, data: Array(repeating: 0, count: 30))[0], now: now)
        _ = r.add(try f.fragments(frameId: 4, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [1])[0], now: now)
        #expect(r.counters.framesLost == 2)                 // 2 dropped partial, 3 never seen
        #expect(r.counters.fragmentsExpected == 5 && r.counters.fragmentsReceived == 3)
    }
}

@Suite("Rate control")
struct RateControllerTests {
    let ms: UInt64 = 1_000_000

    @Test func delayTrackerSeesAQueue() {
        var d = DelayTracker()
        let offset: UInt64 = 1_000_000_000_000            // clocks differ wildly; only the rise matters
        for i in 0..<50 { d.add(arrivalNs: offset + UInt64(i) * 16 * ms + 20 * ms, captureNs: UInt64(i) * 16 * ms) }
        #expect(d.queuingDelayMicros < 1000)
        for i in 50..<70 { d.add(arrivalNs: offset + UInt64(i) * 16 * ms + 20 * ms + UInt64(i - 49) * 5 * ms, captureNs: UInt64(i) * 16 * ms) }
        #expect(d.queuingDelayMicros > 60_000)
    }

    @Test func delayTrackerForgetsOldMinimum() {
        var d = DelayTracker(windowNs: 1_000_000_000)
        d.add(arrivalNs: 10 * ms, captureNs: 0)            // one lucky early sample
        for i in 1...200 { d.add(arrivalNs: UInt64(i) * 10 * ms + 40 * ms, captureNs: UInt64(i) * 10 * ms) }
        #expect(d.queuingDelayMicros < 1000)               // the new base is 40 ms, not 10 ms
    }

    @Test func backsOffOnQueueAndLoss() {
        var c = BitrateController(start: 50_000_000, max: 80_000_000)
        c.update(nowNs: 1000 * ms, loss: 0, framesLost: 0, queuingDelayMs: 150, sentBitrate: 40_000_000)
        #expect(c.bitrate == 35_000_000)
        #expect(!c.inStartup)
        c.update(nowNs: 1100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 150, sentBitrate: 30_000_000)
        #expect(c.bitrate == 35_000_000)                   // at most once per 300 ms
        c.update(nowNs: 1400 * ms, loss: 0.05, framesLost: 2, queuingDelayMs: 5, sentBitrate: 30_000_000)
        #expect(c.bitrate == 30_800_000)
    }

    @Test func neverBelowMinimum() {
        var c = BitrateController(start: 2_000_000, min: 1_500_000, max: 10_000_000)
        for i in 1...20 { c.update(nowNs: UInt64(i) * 400 * ms, loss: 0.5, framesLost: 10, queuingDelayMs: 200, sentBitrate: 0) }
        #expect(c.bitrate == 1_500_000)
    }

    @Test func congestiveLossCapsPacing() {
        var c = BitrateController(start: 10_000_000, max: 50_000_000)
        #expect(c.pacingRate == 25_000_000)
        c.update(nowNs: 1000 * ms, loss: 0.2, framesLost: 4, queuingDelayMs: 5, sentBitrate: 10_000_000)
        #expect(c.pacingCap == 21_250_000)                 // 85% of the 25 Mbit/s that overflowed
        #expect(c.bitrate == 7_000_000 && c.pacingRate == 17_500_000)
        for i in 11...40 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: c.bitrate) }
        #expect(c.bitrate > 9_000_000)
        #expect(c.pacingRate < Int(Double(c.bitrate) * 2.5))    // the cap, not the factor, limits it now
        #expect(c.pacingRate >= Int(Double(c.bitrate) * 1.15))
        #expect(c.pacingCap! > 21_250_000)                 // and it creeps back up on a clean path
    }

    @Test func randomLossLeavesPacingAlone() {
        var c = BitrateController(start: 10_000_000, max: 50_000_000)
        for i in 1...30 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0.01, framesLost: 0, queuingDelayMs: 3, sentBitrate: c.bitrate) }
        #expect(c.pacingCap == nil && c.parityGroup == 10)
    }

    @Test func jitterAloneIsNotAQueue() {
        var c = BitrateController(start: 10_000_000, max: 50_000_000)
        for i in 1...40 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0.004, framesLost: 0, queuingDelayMs: Double(i % 3) * 8, sentBitrate: c.bitrate) }
        #expect(c.inStartup && c.bitrate == 50_000_000)
    }

    @Test func startupRampsFastThenSlows() {
        var c = BitrateController(start: 8_000_000, max: 50_000_000)
        for i in 1...10 { c.update(nowNs: UInt64(i) * 250 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: c.bitrate) }
        #expect(c.bitrate > 40_000_000)                    // ~2.5 s from 8 to near the ceiling
        c.update(nowNs: 3000 * ms, loss: 0.2, framesLost: 5, queuingDelayMs: 2, sentBitrate: c.bitrate)
        let after = c.bitrate
        for i in 13...16 { c.update(nowNs: UInt64(i) * 250 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: c.bitrate) }
        #expect(c.bitrate <= after * 109 / 100)            // one 8% step at most after leaving start-up
    }

    @Test func growsOnlyWhileTheEncoderUsesIt() {
        var c = BitrateController(start: 10_000_000, max: 50_000_000)
        for i in 1...40 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: 500_000) }
        #expect(c.bitrate == 10_000_000)                   // static screen: no growth
        for i in 41...80 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: c.bitrate) }
        #expect(c.bitrate > 15_000_000 && c.bitrate <= 50_000_000)
    }

    @Test func convergesUnderACap() {
        // A 12 Mbit/s drop-tail bottleneck with a 150 ms buffer, 10 ms of jitter: the queue grows while
        // sending above the cap and drains below it; a full buffer drops.
        var c = BitrateController(start: 8_000_000, max: 80_000_000)
        var queueMs = 0.0
        var tail: [Int] = []
        for i in 1...600 {
            queueMs = max(0, queueMs + (Double(c.bitrate) / 12_000_000 - 1) * 100)
            let loss = queueMs > 150 ? 0.15 : 0
            queueMs = min(queueMs, 150)
            c.update(nowNs: UInt64(i) * 100 * ms, loss: loss, framesLost: loss > 0 ? 3 : 0,
                     queuingDelayMs: queueMs + Double(i % 3) * 5, sentBitrate: c.bitrate)
            if i > 300 { tail.append(c.bitrate) }
        }
        let mean = Double(tail.reduce(0, +)) / Double(tail.count)
        #expect(mean > 8_500_000 && mean < 12_500_000, "mean \(mean)")
    }

    @Test func fecFollowsLossAndSwitchesOffSlowly() {
        var c = BitrateController(start: 10_000_000, max: 20_000_000)
        for i in 1...30 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0.05, framesLost: 0, queuingDelayMs: 2, sentBitrate: 0) }
        #expect(c.parityGroup == 5)
        for i in 31...50 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: 0) }
        #expect(c.parityGroup != 0)                        // 2 s clean is not enough
        for i in 51...150 { c.update(nowNs: UInt64(i) * 100 * ms, loss: 0, framesLost: 0, queuingDelayMs: 2, sentBitrate: 0) }
        #expect(c.parityGroup == 0)
    }

    @Test func pacerSpreadsABurst() {
        var p = Pacer(bitrate: 10_000_000, factor: 2.5, burstBytes: 12_000)
        var t: UInt64 = 0
        for _ in 0..<50 {                                  // 60 KB frame
            t += p.delayNs(for: 1200, nowNs: t)
            p.sent(1200, nowNs: t)
        }
        // First 12 KB go at once; the remaining 48 KB at 25 Mbit/s take ~15.4 ms.
        #expect(t > 14 * ms && t < 17 * ms)
        #expect(p.delayNs(for: 1200, nowNs: t + 100 * ms) == 0)
    }
}

@Suite("Reassembler chain")
struct ChainTests {
    /// Trailing parity after a keyframe completes (and the chain resets) must not open a phantom frame.
    @Test func lateFragmentsAfterResetAreIgnored() throws {
        let f = try Fragmenter(maxFragmentPayload: 100).fragments(frameId: 1, flags: .keyframe, formatGeneration: 1, captureTimeNs: 0,
                                                                  data: Array(repeating: 3, count: 900), parityGroup: 3)
        var r = Reassembler()
        var ev: [Reassembler.Event] = []
        for x in f where !x.flags.contains(.parity) { ev += r.add(x, now: .now) }
        #expect(ev.count == 1)
        r.resetChain()
        for x in f where x.flags.contains(.parity) { ev += r.add(x, now: .now) }
        ev += r.add(f[0], now: .now)                          // a late duplicate
        #expect(ev.count == 1)
        #expect(r.expire(now: .now + .seconds(5)).isEmpty)
        #expect(r.counters.framesLost == 0)
    }
}
