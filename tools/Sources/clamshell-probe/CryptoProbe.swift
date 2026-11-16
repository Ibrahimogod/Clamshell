import ClamshellRateControl
import ClamshellSession
import ClamshellWire
import Foundation

/// Probe 3: per-frame cost of the real send path (fragment → inner message → Noise transport seal)
/// and the receive path (open → decode → reassemble). Target: seal < 0.5 ms per typical frame.
enum CryptoProbe {
    static func run(_ args: Args) throws {
        let iterations = args.int("iterations", 300)
        let psk = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let host = StaticIdentity(), phone = StaticIdentity()
        var responder = HostResponder(identity: host, peers: [PeerConfig(publicKey: phone.publicKey, psk: psk, name: "phone")])
        var client = try ClientHandshake(identity: phone, server: PeerConfig(publicKey: host.publicKey, psk: psk, name: "mac"), payload: [])
        let hsStart = ContinuousClock.now
        let accepted = try responder.handleInitiation(client.initiationPacket, now: .now) { _ in [] }
        var phoneSession = try client.complete(response: accepted.responsePacket, now: .now).session
        let handshakeMs = ms(ContinuousClock.now - hsStart)
        var macSession = accepted.session
        // Confirm the responder session (it needs one authentic initiator packet first).
        _ = try macSession.open(try phoneSession.seal(Ping(id: 0, t1: 0).message.encoded, now: .now), now: .now)

        print("# clamshell-probe crypto — Noise IKpsk2 transport (ChaChaPoly, CryptoKit)")
        print("handshake (both sides, in-process): \(fmt(handshakeMs)) ms")
        let budget = Fragmenter.payloadBudget(datagram: 1200, sessionOverhead: SecureSession.overhead)
        let fragmenter = Fragmenter(maxFragmentPayload: budget)
        print("fragment payload budget: \(budget) bytes per 1200-byte datagram")
        print("| frame | datagrams | seal path p50 ms | p95 ms | open+reassemble p50 ms | p95 ms | seal throughput MB/s |")
        print("|---|---|---|---|---|---|---|")
        var verdict: [String] = []
        for (label, size) in [("cursor blink 2 KB", 2_000), ("typing 12 KB", 12_000), ("scroll 40 KB", 40_000),
                              ("keyframe 300 KB", 300_000), ("big keyframe 900 KB", 900_000)] {
            let frame = (0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            var sealTimes: [Double] = [], openTimes: [Double] = []
            var datagrams = 0
            var reassembler = Reassembler()
            for i in 0..<iterations {
                let t0 = ContinuousClock.now
                let fragments = try fragmenter.fragments(frameId: UInt32(i + 1), flags: i == 0 ? [.keyframe] : [], formatGeneration: 1,
                                                         captureTimeNs: 0, data: frame)
                var packets: [[UInt8]] = []
                packets.reserveCapacity(fragments.count)
                for f in fragments { packets.append(try macSession.seal(f.message.encoded, now: t0)) }
                let t1 = ContinuousClock.now
                datagrams = packets.count
                var completed = false
                for p in packets {
                    let plain = try phoneSession.open(p, now: t1)
                    for m in try InnerMessage.decodeAll(plain) {
                        for e in reassembler.add(try VideoFragment(m), now: t1) {
                            if case .complete = e { completed = true }
                        }
                    }
                }
                let t2 = ContinuousClock.now
                guard completed else { throw ProbeFailure("frame \(i) did not reassemble") }
                sealTimes.append(ms(t1 - t0))
                openTimes.append(ms(t2 - t1))
            }
            let s = stats(sealTimes), o = stats(openTimes)
            let mbps = s.p50.map { Double(size) / ($0 / 1000) / 1e6 }
            print("| \(label) | \(datagrams) | \(fmt(s.p50, 3)) | \(fmt(s.p95, 3)) | \(fmt(o.p50, 3)) | \(fmt(o.p95, 3)) | \(fmt(mbps, 0)) |")
            if size == 40_000 { verdict.append("typical 40 KB frame seal p50 \(fmt(s.p50, 3)) ms → \((s.p50 ?? 99) < 0.5 ? "PASS" : "FAIL") (< 0.5 ms)") }
        }
        verdict.forEach { print($0) }
    }
}
