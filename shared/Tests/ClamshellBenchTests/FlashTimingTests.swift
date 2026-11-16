import Testing
@testable import ClamshellBench

@Suite("Flash timing (one-device harness B)")
struct FlashTimingTests {
    /// A square that is dark (20) before `flipNs` and bright (230) after, sampled every `periodNs`, with the
    /// sample straddling the flip catching it part-way (as a camera exposure or a scan-out does).
    /// `blend: false` is a decoded picture: it shows either the old or the new state, never a mix.
    func samples(flips: [UInt64], periodNs: UInt64, count: Int, phaseNs: UInt64 = 0, blend: Bool = true) -> [(UInt64, Double)] {
        (0..<count).map { i in
            let t = phaseNs + UInt64(i) * periodNs
            let on = flips.filter { $0 <= t }.count % 2 == 1
            let start = t - min(t, periodNs)
            if blend, let f = flips.first(where: { $0 > start && $0 <= t }) {
                let frac = Double(t - f) / Double(periodNs)          // share of the exposure after the flip
                let after = on ? 230.0 : 20.0, before = on ? 20.0 : 230.0
                return (t, before + (after - before) * frac)
            }
            return (t, on ? 230 : 20)
        }
    }

    @Test func learnedThresholdFindsFlipsWithSubFrameTiming() {
        var d = FlashEdgeDetector()
        let flips: [UInt64] = [100_000_000, 550_000_000, 1_000_000_000]
        let edges = samples(flips: flips, periodNs: 4_166_667, count: 300).compactMap { d.add(timeNs: $0.0, level: $0.1) }
        // The first flip teaches the threshold. An exposure-averaged sample crosses the midpoint half a frame
        // after the true flip, so each edge lands at flip + period/2, within a third of a frame.
        #expect(edges.count >= 2)
        for e in edges {
            let expected = (flips.min { abs(Int64($0) - Int64(e.timeNs)) < abs(Int64($1) - Int64(e.timeNs)) } ?? 0) + 4_166_667 / 2
            #expect(abs(Int64(expected) - Int64(e.timeNs)) < 1_400_000, "\(e) vs \(expected)")
        }
        #expect(edges.last?.rising == true)
    }

    @Test func noFlipsWithoutEnoughSwing() {
        var d = FlashEdgeDetector()
        let edges = (0..<200).compactMap { i in d.add(timeNs: UInt64(i) * 4_000_000, level: 100 + Double(i % 7)) }
        #expect(edges.isEmpty)
        #expect(d.threshold == nil)
    }

    @Test func matcherMeasuresLagAndIgnoresStrays() {
        var m = FlashMatcher()
        for k in 0..<10 {
            let t = UInt64(k) * 450_000_000
            m.addReference(FlashEdge(timeNs: t, rising: k % 2 == 0))
            #expect(m.addFollower(FlashEdge(timeNs: t + 38_000_000, rising: k % 2 == 0)) == 38)
        }
        // Wrong direction, too late and early: not matched.
        m.addReference(FlashEdge(timeNs: 10_000_000_000, rising: true))
        #expect(m.addFollower(FlashEdge(timeNs: 10_030_000_000, rising: false)) == nil)
        #expect(m.addFollower(FlashEdge(timeNs: 10_500_000_000, rising: true)) == nil)
        #expect(m.addFollower(FlashEdge(timeNs: 9_990_000_000, rising: true)) == nil)
        #expect(m.lagsMs.count == 10)
    }

    @Test func followerBeforeItsReferenceStillMatches() {
        // The camera frame is processed after the phone has already presented the flip.
        var m = FlashMatcher()
        #expect(m.addFollower(FlashEdge(timeNs: 1_045_000_000, rising: true)) == nil)
        #expect(m.addReference(FlashEdge(timeNs: 1_000_000_000, rising: true)) == 45)
        #expect(m.addReference(FlashEdge(timeNs: 1_450_000_000, rising: false)) == nil)
        #expect(m.addFollower(FlashEdge(timeNs: 1_490_000_000, rising: false)) == 40)
        #expect(m.lagsMs == [45, 40])
    }

    @Test func discreteDetectorReportsTheFirstPictureNotAnInterpolation() {
        // Damage skip: nothing for 400 ms, then the white picture. The flip is that picture, not halfway back.
        var d = FlashEdgeDetector(fixedThreshold: 128, interpolates: false)
        #expect(d.add(timeNs: 100_000_000, level: 16) == nil)
        #expect(d.add(timeNs: 500_000_000, level: 235) == FlashEdge(timeNs: 500_000_000, rising: true))
    }

    @Test func aLevelHoveringAtTheThresholdIsOneFlip() {
        // A slow, noisy transition (rolling shutter mid-flip): 135, 118, 140 all sit near the midpoint 125.
        var d = FlashEdgeDetector(confirmSamples: 2)
        let levels: [Double] = [20, 230, 230, 230, 20, 20, 20, 120, 135, 118, 140, 230, 230, 230, 230]
        let edges = levels.enumerated().compactMap { i, v in d.add(timeNs: UInt64(i) * 4_000_000, level: v) }
        // The 230 → 20 fall, then exactly one rise: placed where 118 → 140 crossed 125, not at 120 → 135.
        #expect(edges.map(\.rising) == [false, true])
        let rise = edges.last?.timeNs ?? 0
        #expect(rise > 36_000_000 && rise < 40_000_000, "\(rise)")
    }

    @Test func aOneFrameGlitchNeedsConfirming() {
        var d = FlashEdgeDetector(confirmSamples: 2)
        let levels: [Double] = [230, 230, 20, 20, 20, 230, 20, 20, 20, 230, 20, 20]  // dark from frame 2; later 230s are one-frame glitches
        let edges = levels.enumerated().compactMap { i, v in d.add(timeNs: UInt64(i) * 4_000_000, level: v) }
        #expect(edges.isEmpty)
    }

    @Test func endToEndThroughBothDetectors() {
        // Camera at 240 fps sees the Mac flips; the phone presents them 41 ms later at 120 Hz.
        let flips: [UInt64] = (1...12).map { UInt64($0) * 470_000_000 }
        var cam = FlashEdgeDetector(), screen = FlashEdgeDetector(fixedThreshold: 128, interpolates: false), m = FlashMatcher()
        var events: [(UInt64, Bool, FlashEdge)] = []
        for (t, v) in samples(flips: flips, periodNs: 4_166_667, count: 1500) {
            if let e = cam.add(timeNs: t, level: v) { events.append((t, true, e)) }
        }
        for (t, v) in samples(flips: flips.map { $0 + 41_000_000 }, periodNs: 8_333_333, count: 750, phaseNs: 2_000_000, blend: false) {
            if let e = screen.add(timeNs: t, level: v) { events.append((t, false, e)) }
        }
        for (_, isCam, e) in events.sorted(by: { $0.0 < $1.0 }) {
            if isCam { m.addReference(e) } else { m.addFollower(e) }
        }
        #expect(m.lagsMs.count >= 10)
        let sorted = m.lagsMs.sorted()
        let p50 = sorted[sorted.count / 2]
        // Camera edges land half a camera frame late (+2.1 ms), phone edges at the next 120 Hz picture (0–8.3 ms).
        #expect(abs(p50 - 41) < 6, "\(m.lagsMs)")
    }
}

@Suite("Flash spot finder")
struct FlashSpotFinderTests {
    @Test func picksTheFlashingCellOverRampsAndOneOffs() {
        // 4 cells: 0 still, 1 slow exposure ramp, 2 the flashing square, 3 a hand passing once (bright then back).
        var f = FlashSpotFinder(cellCount: 4)
        for i in 0..<720 {                                   // 3 s at 240 fps, flips every ~110 frames
            let flash = (i / 110) % 2 == 0 ? 25.0 : 210.0
            let hand = (300..<340).contains(i) ? 200.0 : 60.0
            f.add([90, 40 + Double(i) * 0.2, flash, hand])
        }
        #expect(f.best() == 2)
    }

    @Test func nothingQualifiesWithoutAFlash() {
        var f = FlashSpotFinder(cellCount: 2)
        for i in 0..<500 { f.add([100 + Double(i % 5), 30]) }
        #expect(f.best() == nil)
        f.reset()
        #expect(f.frames == 0)
    }
}
