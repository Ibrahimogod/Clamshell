import Foundation
import Testing
import ClamshellWire
@testable import ClamshellSession

/// Deterministic fuzzing of the Noise packet handlers (M6, docs/security.md T6/T8/T13): mutated handshake
/// initiations (with MAC1 recomputed, so they reach the DH and AEAD), mutated transport packets, and
/// mutated pairing packets. All must be rejected without crashing, and none may yield a session or data.
@Suite("Fuzz: Noise handlers (M6)")
struct SessionFuzzTests {
    static let iterations = Int(ProcessInfo.processInfo.environment["CLAMSHELL_FUZZ_ITERATIONS"] ?? "") ?? 3_000

    struct Rng: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    static func mutate(_ p: [UInt8], keepPrefix: Int, _ rng: inout Rng) -> [UInt8] {
        var b = p
        for _ in 0..<Int.random(in: 1...4, using: &rng) {
            switch Int.random(in: 0...2, using: &rng) {
            case 0 where b.count > keepPrefix: b[Int.random(in: keepPrefix..<b.count, using: &rng)] ^= UInt8(1 << Int.random(in: 0...7, using: &rng))
            case 1 where b.count > keepPrefix: b.removeLast(Int.random(in: 1...(b.count - keepPrefix), using: &rng))
            default: b.append(contentsOf: (0..<Int.random(in: 1...32, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
            }
        }
        return b
    }

    @Test func mutatedInitiationsAreRejected() throws {
        let pair = Pair()
        var responder = pair.responder()
        var rng = Rng(state: 0x1F00)
        let good = try pair.client().initiationPacket
        var accepted = 0
        for _ in 0..<Self.iterations {
            var p = Self.mutate(good, keepPrefix: 1, &rng)
            if Bool.random(using: &rng), p.count > HandshakePacket.macLength {
                // Re-MAC so the packet gets past the cheap check and into the Noise processing.
                let split = p.count - HandshakePacket.macLength
                p.replaceSubrange(split..., with: HandshakePacket.mac1(receiverStatic: pair.mac.publicKey, p[..<split]))
            }
            // The 8-byte clear header (type, reserved, sender index) is covered only by MAC1, as in
            // WireGuard: changing it gives a session the real phone can't use (DoS, never data).
            let noiseChanged = p.count != good.count || p[HandshakePacket.initiationHeader..<(p.count - HandshakePacket.macLength)]
                != good[HandshakePacket.initiationHeader..<(good.count - HandshakePacket.macLength)]
            if (try? responder.handleInitiation(p, now: .now) { _ in [] }) != nil, noiseChanged { accepted += 1 }
        }
        #expect(accepted == 0)
    }

    @Test func mutatedTransportPacketsAreRejected() throws {
        var (phone, mac, _) = try Pair().establish()
        var rng = Rng(state: 0x7A45)
        let first = try phone.seal(Ping(id: 1, t1: 2).message.encoded, now: .now)
        _ = try mac.open(first, now: .now)                    // confirms the session
        var opened = 0
        for i in 0..<Self.iterations {
            let good = try phone.seal(Ping(id: UInt32(i), t1: 2).message.encoded, now: .now)
            let bad = Self.mutate(good, keepPrefix: 8, &rng)  // keep type + receiver index so it finds the session
            if bad != good, (try? mac.open(bad, now: .now)) != nil { opened += 1 }
            _ = SecureSession.receiverIndex(of: Self.mutate(good, keepPrefix: 0, &rng))
        }
        #expect(opened == 0)
    }

    @Test func mutatedPairingPacketsAreHarmless() throws {
        let pair = Pair()
        let invite = PairingInvite(macPublicKey: pair.mac.publicKey, secret: [UInt8](repeating: 7, count: 10), macName: "Mac", port: 1)
        var window = PairingWindow(identity: pair.mac, invite: invite, now: .now)
        var rng = Rng(state: 0xBA1D)
        let p = try PairingInitiator(identity: pair.phone, invite: invite, phoneName: "Duo")
        let good = p.currentPacket
        var requests = 0
        for _ in 0..<Self.iterations {
            if case .request = window.handle(Self.mutate(good, keepPrefix: 1, &rng), now: .now) { requests += 1 }
        }
        #expect(requests == 0)
    }
}
