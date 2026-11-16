import ClamshellTransport
import Testing

@Suite("Handshake limiter (M6, T8)")
struct HandshakeLimiterTests {
    @Test func perSourceBurstThenRefill() {
        var l = HandshakeLimiter(nowNs: 0)
        var ok = 0
        for _ in 0..<100 where l.allow(host: "198.51.100.7", nowNs: 1) { ok += 1 }
        #expect(ok == 30)
        let other = l.allow(host: "198.51.100.8", nowNs: 1)    // another source isn't affected
        #expect(other)
        let tooSoon = l.allow(host: "198.51.100.7", nowNs: 1_000_000_000)
        #expect(!tooSoon)
        let refilled = l.allow(host: "198.51.100.7", nowNs: 2_100_000_000)   // 0.5 a second
        #expect(refilled)
    }

    @Test func globalCap() {
        var l = HandshakeLimiter(nowNs: 0)
        var ok = 0
        for i in 0..<1000 where l.allow(host: "203.0.113.\(i % 250)-\(i)", nowNs: 1) { ok += 1 }
        #expect(ok == 200)
        #expect(l.refused == 800)
    }

    @Test func spoofedFloodStaysBounded() {
        var l = HandshakeLimiter(nowNs: 0)
        for i in 0..<20_000 { _ = l.allow(host: "h\(i)", nowNs: UInt64(i) * 1_000_000) }
        // Memory stays bounded (pruned at 4096); a real phone still gets in once the flood passes.
        let phone = l.allow(host: "phone", nowNs: 30_000_000_000)
        #expect(phone)
    }
}
