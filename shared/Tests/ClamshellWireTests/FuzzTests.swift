import Foundation
import Testing
@testable import ClamshellWire

/// Deterministic fuzzing (M6, docs/security.md T3/T13): random and mutated bytes into every decoder that
/// reads network input. Decoders may throw; they must never crash, hang or allocate without bound.
/// `CLAMSHELL_FUZZ_ITERATIONS` raises the count for a long run (default 20 000 per target).
struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

enum Fuzz {
    static let iterations = Int(ProcessInfo.processInfo.environment["CLAMSHELL_FUZZ_ITERATIONS"] ?? "") ?? 20_000

    /// Valid encodings to mutate (the golden fixtures, one per message type), so the fuzzer gets past the
    /// header and into each body decoder.
    static let seeds: [[UInt8]] = {
        let samples = FixtureTests.samples.map(\.message.encoded)
        return samples + [samples.flatMap { $0 }]
    }()

    static func input(_ rng: inout SplitMix64) -> [UInt8] {
        if Bool.random(using: &rng) {
            let n = Int.random(in: 0...200, using: &rng)
            return (0..<n).map { _ in UInt8.random(in: 0...255, using: &rng) }
        }
        var b = seeds.randomElement(using: &rng) ?? []
        for _ in 0..<Int.random(in: 1...6, using: &rng) {
            switch Int.random(in: 0...4, using: &rng) {
            case 0 where !b.isEmpty: b[Int.random(in: 0..<b.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            case 1 where !b.isEmpty: b.removeLast(Int.random(in: 0...b.count, using: &rng))
            case 2: b.insert(UInt8.random(in: 0...255, using: &rng), at: Int.random(in: 0...b.count, using: &rng))
            case 3 where !b.isEmpty: b[Int.random(in: 0..<b.count, using: &rng)] = [0x00, 0x7F, 0x80, 0xFF].randomElement(using: &rng) ?? 0
            default:                                        // a huge varint length, the classic over-allocation bait
                b.insert(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x7F], at: Int.random(in: 0...b.count, using: &rng))
            }
        }
        return b
    }

    /// Every body decoder, by type.
    static func decodeBody(_ m: InnerMessage) {
        let b = m.body
        _ = try? Hello(body: b); _ = try? Incompatible(body: b); _ = try? Ping(body: b); _ = try? Pong(body: b)
        _ = try? Goodbye(body: b); _ = try? KeyframeRequest(body: b); _ = try? HostStats(body: b)
        _ = try? KeyEvent(body: b); _ = try? PointerMove(body: b); _ = try? PointerButtonEvent(body: b)
        _ = try? ScrollEvent(body: b); _ = try? GestureEvent(body: b); _ = try? InputState(body: b)
        _ = try? CursorPosition(body: b); _ = try? CursorShape(body: b); _ = try? BulkChunk(body: b); _ = try? BulkAck(body: b)
        _ = try? ClipboardOffer(body: b); _ = try? FileOffer(body: b); _ = try? AudioPacket(body: b)
        _ = try? VideoFormat(body: b); _ = try? VideoFragment(body: b); _ = try? ReceiverReport(body: b)
        _ = try? HostState(body: b); _ = try? HomeEndpoint(body: b); _ = try? DisplayModeRequest(body: b)
        _ = try? KeyboardLayout(body: b)
    }
}

@Suite("Fuzz: wire decoders (M6)")
struct WireFuzzTests {
    @Test func innerMessagesAndBodies() {
        var rng = SplitMix64(state: 0xC1A5_5E11)
        var decoded = 0
        for _ in 0..<Fuzz.iterations {
            let bytes = Fuzz.input(&rng)
            _ = try? TLVReader(bytes, knownTags: [1, 2, 3])
            guard let msgs = try? InnerMessage.decodeAll(bytes) else { continue }
            decoded += msgs.count
            for m in msgs { Fuzz.decodeBody(m) }
        }
        #expect(decoded > 0)                                  // the mutations reach the body decoders
    }

    /// Bodies straight in, without the header's own checks in front.
    @Test func rawBodies() {
        var rng = SplitMix64(state: 0xB0D1E5)
        for _ in 0..<Fuzz.iterations {
            let bytes = Fuzz.input(&rng)
            Fuzz.decodeBody(InnerMessage(channel: .control, type: .hello, body: bytes))
        }
    }

    /// The bulk reassembler with hostile chunks: wrong counts, indices, ids, duplicates.
    @Test func bulkReceiver() {
        var rng = SplitMix64(state: 0xB01C)
        var r = BulkReceiver()
        var now: UInt64 = 0
        for _ in 0..<Fuzz.iterations {
            now += 1_000_000
            let count = UInt16.random(in: 1...40, using: &rng)
            let c = BulkChunk(transferId: UInt32.random(in: 0...8, using: &rng), index: UInt16.random(in: 0..<count, using: &rng),
                              count: count, data: (0..<Int.random(in: 0...64, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            guard let parsed = try? BulkChunk(c.message) else { continue }
            let out = r.add(parsed, nowNs: now)
            if let m = out.completed { Fuzz.decodeBody(m) }
        }
    }
}

@Suite("HostState 1.5")
struct HostStateLocalUserTests {
    @Test func localUserRoundTripsAndOldStateDecodes() throws {
        let on = try HostState(HostState(screen: .active, keepsAwake: true, targetBitrateKbps: 1, localUser: true).message)
        #expect(on.localUser)
        let off = HostState(screen: .active, keepsAwake: true, targetBitrateKbps: 1)
        let decoded = try HostState(off.message)
        #expect(!decoded.localUser)
    }
}
