import CoreGraphics
import Testing
@testable import ClamshellInput

@Suite("Posture (ADR-0012)")
struct PostureTests {
    let portrait = CGSize(width: 400, height: 900)
    let landscape = CGSize(width: 900, height: 400)

    @Test func hingeRules() {
        #expect(PostureInference.infer(.init(hinge: .closed, bounds: portrait)) == .cover)
        #expect(PostureInference.infer(.init(hinge: .fullyOpen, division: CGRect(x: 0, y: 440, width: 400, height: 20), bounds: portrait)) == .flat)
        #expect(PostureInference.infer(.init(hinge: .partiallyOpen, division: CGRect(x: 0, y: 440, width: 400, height: 20), bounds: portrait)) == .laptop)
        #expect(PostureInference.infer(.init(hinge: .partiallyOpen, division: CGRect(x: 440, y: 0, width: 20, height: 400), bounds: landscape)) == .book)
    }

    @Test func fallbacksWithoutHinge() {
        #expect(PostureInference.infer(.init(bounds: portrait)) == .laptop)
        #expect(PostureInference.infer(.init(bounds: landscape)) == .flat)
        #expect(PostureInference.infer(.init(hinge: .partiallyOpen, bounds: landscape)) == .book)
        #expect(PostureInference.infer(.init(hinge: .unknown, division: CGRect(x: 440, y: 0, width: 20, height: 400), bounds: landscape)) == .book)
        #expect(PostureInference.infer(.init(hinge: .partiallyOpen, division: .zero, bounds: portrait)) == .laptop)
    }

    @Test func debounceUIThenDisplay() {
        var d = PostureDebouncer(initial: .laptop, nowNs: 0)
        let c405 = d.observe(.flat, nowNs: 10_000_000); #expect(!c405)
        #expect(d.ui == .laptop)
        let c122 = d.tick(nowNs: 170_000_000); #expect(c122)
        #expect(d.ui == .flat && d.display == .laptop)
        let c202 = d.tick(nowNs: 620_000_000); #expect(c202)
        #expect(d.display == .flat)
    }

    @Test func flickerNeverReachesLayout() {
        var d = PostureDebouncer(initial: .laptop, nowNs: 0)
        var t: UInt64 = 0
        for i in 0..<20 { t += 100_000_000; d.observe(i % 2 == 0 ? .flat : .laptop, nowNs: t) }
        #expect(d.ui == .laptop && d.display == .laptop)
    }

    @Test func pinOverrides() {
        var d = PostureDebouncer(initial: .laptop, nowNs: 0)
        d.pin(.flat)
        #expect(d.effective == .flat)
        d.observe(.book, nowNs: 1)
        d.tick(nowNs: 1_000_000_000)
        #expect(d.effective == .flat && d.ui == .book)
        d.pin(nil)
        #expect(d.effective == .book)
    }

    @Test func optionTabBecomesCommandTab() {
        var r = HardwareKeyRemap()
        do { let e = r.handle(0xE2, down: true); #expect(e == [.key(0xE2, down: true)]) }
        do { let e = r.handle(0x2B, down: true); #expect(e == [.key(0xE2, down: false), .key(0xE3, down: true), .key(0x2B, down: true)]) }
        do { let e = r.handle(0x2B, down: false); #expect(e == [.key(0x2B, down: false)]) }
        do { let e = r.handle(0x2B, down: true); #expect(e == [.key(0x2B, down: true)]) }           // still ⌘ held: next app
        do { let e = r.handle(0x2B, down: false); #expect(e == [.key(0x2B, down: false)]) }
        do { let e = r.handle(0xE2, down: false); #expect(e == [.key(0xE3, down: false)]) }
        // Plain ⌥ use is untouched.
        do { let e = r.handle(0xE2, down: true); #expect(e == [.key(0xE2, down: true)]) }
        do { let e = r.handle(0x04, down: true); #expect(e == [.key(0x04, down: true)]) }
    }

    @Test func controlSpaceBecomesCommandSpaceAndCanBeOff() {
        var r = HardwareKeyRemap()
        _ = r.handle(0xE4, down: true)
        do { let e = r.handle(0x2C, down: true); #expect(e == [.key(0xE4, down: false), .key(0xE3, down: true), .key(0x2C, down: true)]) }
        var off = HardwareKeyRemap(); off.enabled = false
        _ = off.handle(0xE0, down: true)
        do { let e = off.handle(0x2C, down: true); #expect(e == [.key(0x2C, down: true)]) }
    }
}
