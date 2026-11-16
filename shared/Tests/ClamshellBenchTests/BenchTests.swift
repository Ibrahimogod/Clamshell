import Testing
@testable import ClamshellBench

@Suite("Bench")
struct BenchTests {
    @Test(arguments: [(UInt32(0), UInt32(0)), (1, 1), (0xFF_FFFF, 0xFFFF_FFFF), (123_456, 987_654_321)])
    func barcodeRoundTrip(_ seq: UInt32, _ micros: UInt32) {
        let v = BarcodePatch.Value(sequence: seq, timeMicros: micros)
        let cells = BarcodePatch.encode(v)
        #expect(cells.count == 64)
        #expect(BarcodePatch.decode(cells) == v)
    }

    @Test func barcodeDetectsSingleBitErrors() {
        let cells = BarcodePatch.encode(.init(sequence: 4242, timeMicros: 31_337))
        for i in 0..<64 {
            var bad = cells
            bad[i].toggle()
            #expect(BarcodePatch.decode(bad) == nil, "bit \(i)")
        }
        #expect(BarcodePatch.decode(Array(cells.prefix(63))) == nil)
    }

    @Test func sequenceMasked() {
        #expect(BarcodePatch.Value(sequence: 0x1FF_FFFF, timeMicros: 0).sequence == 0xFF_FFFF)
    }

    @Test func unwrapMicros() {
        let period: UInt64 = 1 << 32
        #expect(BarcodePatch.unwrapMicros(10, near: 5 * period + 20) == 5 * period + 10)
        #expect(BarcodePatch.unwrapMicros(UInt32.max - 5, near: 5 * period + 3) == 5 * period - 6)
        #expect(BarcodePatch.unwrapMicros(4, near: 6 * period - 2) == 6 * period + 4)
    }

    @Test func clockSync() throws {
        var c = ClockSync(window: 4)
        // Remote is 5 µs ahead, one-way 100 ns each way.
        let added = c.add(t1: 1_000, t2: 6_100, t3: 6_200, t4: 1_300)
        let s = try #require(added)
        #expect(s.offsetNs == 5_000)
        #expect(s.delayNs == 200)
        // A noisier sample (queued on the way back) is kept but not chosen.
        c.add(t1: 2_000, t2: 7_100, t3: 7_200, t4: 2_900)
        #expect(c.best == s)
        #expect(c.toLocal(remoteNs: 6_100) == 1_100)
        let invalid = c.add(t1: 10, t2: 5, t3: 4, t4: 20)
        #expect(invalid == nil, "t3 < t2 is invalid")
    }

    @Test func clockSyncWindowEvictsOldBest() {
        var c = ClockSync(window: 2)
        c.add(t1: 0, t2: 10, t3: 10, t4: 20)          // delay 20
        c.add(t1: 100, t2: 140, t3: 140, t4: 180)     // delay 80
        c.add(t1: 200, t2: 250, t3: 250, t4: 300)     // delay 100, evicts the delay-20 sample
        #expect(c.best?.delayNs == 80)
    }

    @Test func percentiles() {
        var s = LatencyStats(capacity: 100)
        #expect(s.p50 == nil)
        for v in 1...100 { s.add(Double(v)) }
        #expect((50.0...51.0).contains(s.p50 ?? 0))
        #expect(s.p95 == 95)
        #expect(s.percentile(0) == 1 && s.percentile(100) == 100)
        for _ in 0..<100 { s.add(1000) }             // ring buffer replaces everything
        #expect(s.count == 100 && s.p50 == 1000)
        s.add(.nan)
        #expect(s.count == 100)
    }
}
