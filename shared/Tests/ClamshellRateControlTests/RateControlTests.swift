import Testing
import ClamshellWire
@testable import ClamshellRateControl

@Suite("Fragmentation")
struct FragmentationTests {
    let budget = Fragmenter.payloadBudget(datagram: 1200, sessionOverhead: 29)

    func bytes(_ n: Int, seed: UInt8 = 0) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) } }

    @Test func budgetFitsDatagram() throws {
        #expect(budget == 1145)
        let f = Fragmenter(maxFragmentPayload: budget)
        let frags = try f.fragments(frameId: 1, flags: [], formatGeneration: 1, captureTimeNs: 0, data: bytes(budget * 2))
        for frag in frags { #expect(frag.message.encoded.count + 29 <= 1200) }
    }

    @Test(arguments: [0, 1, 1144, 1145, 1146, 3000, 200_000])
    func roundTripShuffled(_ size: Int) throws {
        let data = bytes(size)
        let frags = try Fragmenter(maxFragmentPayload: budget).fragments(frameId: 7, flags: .keyframe, formatGeneration: 2, captureTimeNs: 99, data: data)
        #expect(frags.count == max(1, (size + budget - 1) / budget))
        var r = Reassembler()
        var events: [Reassembler.Event] = []
        for f in frags.shuffled() {
            // Wire round-trip each fragment too.
            events += r.add(try VideoFragment(f.message), now: .now)
        }
        let expected = Reassembler.Frame(frameId: 7, flags: .keyframe, formatGeneration: 2, captureTimeNs: 99, data: data)
        #expect(events == [.complete(expected, precededByGap: false)])
    }

    @Test func duplicateFragmentsIgnored() throws {
        let frags = try Fragmenter(maxFragmentPayload: 10).fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(25))
        var r = Reassembler()
        do { let ok = (r.add(frags[0], now: .now).isEmpty); #expect(ok) }
        do { let ok = (r.add(frags[0], now: .now).isEmpty); #expect(ok) }
        do { let ok = (r.add(frags[1], now: .now).isEmpty); #expect(ok) }
        let ev = r.add(frags[2], now: .now)
        guard case .complete(let frame, _) = ev.first else { Issue.record("expected completion"); return }
        #expect(frame.data == bytes(25))
        do { let ok = (r.add(frags[2], now: .now).isEmpty); #expect(ok, "late duplicate of a completed frame is ignored") }
    }

    @Test func gapDetected() throws {
        let f = Fragmenter(maxFragmentPayload: 100)
        var r = Reassembler()
        _ = r.add(try f.fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [1])[0], now: .now)
        let ev = r.add(try f.fragments(frameId: 3, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [3])[0], now: .now)
        guard case .complete(let frame, let gap) = ev.first else { Issue.record("expected completion"); return }
        #expect(frame.frameId == 3 && gap)
        r.resetChain()
        let ev2 = r.add(try f.fragments(frameId: 9, flags: .keyframe, formatGeneration: 0, captureTimeNs: 0, data: [9])[0], now: .now)
        guard case .complete(_, let gap2) = ev2.first else { Issue.record("expected completion"); return }
        #expect(!gap2)
    }

    @Test func newerCompletionDropsOlderPartial() throws {
        let f = Fragmenter(maxFragmentPayload: 10)
        let five = try f.fragments(frameId: 5, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(30))
        let six = try f.fragments(frameId: 6, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(5))
        var r = Reassembler()
        _ = r.add(five[0], now: .now)
        let ev = r.add(six[0], now: .now)
        #expect(ev.count == 2)
        #expect(ev.first == .dropped(frameId: 5))
        do { let ok = (r.add(five[1], now: .now).isEmpty); #expect(ok, "never complete a frame older than the newest shown") }
        #expect(r.droppedCount == 1 && r.completedCount == 1)
    }

    @Test func timeoutExpires() throws {
        let f = Fragmenter(maxFragmentPayload: 10)
        let frags = try f.fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(30))
        var r = Reassembler(timeout: .milliseconds(250))
        let t0 = ContinuousClock.now
        _ = r.add(frags[0], now: t0)
        do { let ok = (r.expire(now: t0 + .milliseconds(200)).isEmpty); #expect(ok) }
        do { let ok = (r.expire(now: t0 + .milliseconds(250)) == [.dropped(frameId: 1)]); #expect(ok) }
        do { let ok = (r.expire(now: t0 + .seconds(1)).isEmpty); #expect(ok) }
    }

    @Test func pendingBounded() throws {
        let f = Fragmenter(maxFragmentPayload: 10)
        var r = Reassembler(maxPendingFrames: 2)
        var events: [Reassembler.Event] = []
        for id in UInt32(1)...4 {
            events += r.add(try f.fragments(frameId: id, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(30))[0], now: .now)
        }
        #expect(events == [.dropped(frameId: 1), .dropped(frameId: 2)])
    }

    @Test func inconsistentCountDropsFrame() {
        var r = Reassembler()
        _ = r.add(VideoFragment(frameId: 1, index: 0, count: 3, flags: [], formatGeneration: 0, captureTimeNs: 0, payload: [1]), now: .now)
        let ev = r.add(VideoFragment(frameId: 1, index: 1, count: 4, flags: [], formatGeneration: 0, captureTimeNs: 0, payload: [2]), now: .now)
        #expect(ev == [.dropped(frameId: 1)])
    }

    @Test func oversizedFrameDropped() throws {
        var r = Reassembler(maxFrameBytes: 15)
        let frags = try Fragmenter(maxFragmentPayload: 10).fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: bytes(30))
        _ = r.add(frags[0], now: .now)
        do { let ok = (r.add(frags[1], now: .now) == [.dropped(frameId: 1)]); #expect(ok) }
    }

    @Test func tooManyFragmentsRejected() {
        let f = Fragmenter(maxFragmentPayload: 1)
        #expect(throws: Fragmenter.FragmentError.frameTooLarge(70_000)) {
            try f.fragments(frameId: 1, flags: [], formatGeneration: 0, captureTimeNs: 0, data: [UInt8](repeating: 0, count: 70_000))
        }
    }
}

@Suite("Frame policy")
struct FramePolicyTests {
    @Test func latestSlotNeverQueues() {
        let slot = LatestSlot<Int>()
        do { let ok = (!slot.put(1)); #expect(ok) }
        do { let ok = (slot.put(2)); #expect(ok) }
        do { let ok = (slot.put(3)); #expect(ok) }
        do { let ok = (slot.take() == 3); #expect(ok) }
        do { let ok = (slot.take() == nil); #expect(ok) }
        #expect(slot.droppedCount == 2 && slot.deliveredCount == 1)
    }

    @Test func latestSlotConcurrent() async {
        let slot = LatestSlot<Int>()
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<1000 { g.addTask { slot.put(i) } }
            for _ in 0..<100 { g.addTask { _ = slot.take() } }
        }
        _ = slot.take()   // drain the last value so the invariant below is exact
        #expect(slot.droppedCount + slot.deliveredCount == 1000, "every put is either delivered or counted as dropped")
    }

    @Test func refinementStages() {
        var s = RefinementScheduler()
        let t0 = ContinuousClock.now
        do { let ok = (s.poll(now: t0) == nil); #expect(ok, "no change seen yet") }
        s.contentChanged(at: t0)
        #expect(s.nextDeadline == t0 + .milliseconds(120))
        do { let ok = (s.poll(now: t0 + .milliseconds(50)) == nil); #expect(ok) }
        do { let ok = (s.poll(now: t0 + .milliseconds(120)) == .refine(maxQP: 18)); #expect(ok) }
        do { let ok = (s.poll(now: t0 + .milliseconds(130)) == nil); #expect(ok) }
        #expect(s.nextDeadline == t0 + .milliseconds(400))
        do { let ok = (s.poll(now: t0 + .milliseconds(400)) == .refine(maxQP: 12)); #expect(ok) }
        do { let ok = (s.poll(now: t0 + .seconds(5)) == nil); #expect(ok) }
        #expect(s.nextDeadline == nil)
    }

    @Test func refinementRestartsOnChange() {
        var s = RefinementScheduler()
        let t0 = ContinuousClock.now
        s.contentChanged(at: t0)
        do { let ok = (s.poll(now: t0 + .milliseconds(120)) == .refine(maxQP: 18)); #expect(ok) }
        s.contentChanged(at: t0 + .milliseconds(200))
        do { let ok = (s.poll(now: t0 + .milliseconds(300)) == nil); #expect(ok) }
        do { let ok = (s.poll(now: t0 + .milliseconds(320)) == .refine(maxQP: 18)); #expect(ok) }
    }

    @Test func overdueStagesCollapse() {
        var s = RefinementScheduler()
        let t0 = ContinuousClock.now
        s.contentChanged(at: t0)
        do { let ok = (s.poll(now: t0 + .milliseconds(900)) == .refine(maxQP: 12)); #expect(ok) }
        do { let ok = (s.poll(now: t0 + .seconds(2)) == nil); #expect(ok) }
    }

    @Test func droppedRefinementIsRetriedAfterBackoff() {
        var s = RefinementScheduler()
        let t0 = ContinuousClock.now
        s.contentChanged(at: t0)
        do { let ok = (s.poll(now: t0 + .milliseconds(120)) == .refine(maxQP: 18)); #expect(ok) }
        s.refinementDropped(at: t0 + .milliseconds(125))
        do { let ok = (s.poll(now: t0 + .milliseconds(130)) == nil); #expect(ok, "waits for the backoff") }
        #expect(s.nextDeadline == t0 + .milliseconds(145))
        do { let ok = (s.poll(now: t0 + .milliseconds(146)) == .refine(maxQP: 18)); #expect(ok, "same stage again") }
        do { let ok = (s.poll(now: t0 + .milliseconds(400)) == .refine(maxQP: 12)); #expect(ok) }
    }

    @Test func refinementRetriesAreBounded() {
        var s = RefinementScheduler(stages: [.init(delay: .milliseconds(10), maxQP: 12)])
        let t0 = ContinuousClock.now
        s.contentChanged(at: t0)
        var t = t0 + .milliseconds(10)
        var offered = 0
        while t < t0 + .seconds(5) {
            if s.poll(now: t) != nil { offered += 1; s.refinementDropped(at: t) }
            t += .milliseconds(5)
        }
        #expect(offered == RefinementScheduler.maxRetries + 1)
        s.contentChanged(at: t)
        do { let ok = (s.poll(now: t + .milliseconds(10)) == .refine(maxQP: 12)); #expect(ok, "a change resets the budget") }
    }
}
