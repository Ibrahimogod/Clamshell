import Foundation
import Testing
import ClamshellWire
@testable import ClamshellSession

/// Phone ↔ Mac handshake and transport, end to end in memory.
struct Pair {
    let mac = StaticIdentity()
    let phone = StaticIdentity()
    let psk = DevPairingCode.generatePSK()
    let phoneHello = Hello(appVersion: "0.1", build: 1, capabilities: [.hevc444Decode], displayModes: [.laptop], deviceName: "Duo")
    let macHello = Hello(appVersion: "0.1", build: 1, capabilities: [.hevc444Decode, .ltr], deviceName: "Mac")

    var macPeer: PeerConfig { PeerConfig(publicKey: mac.publicKey, psk: psk, name: "Mac") }
    var phonePeer: PeerConfig { PeerConfig(publicKey: phone.publicKey, psk: psk, name: "Duo") }

    func responder() -> HostResponder { HostResponder(identity: mac, peers: [phonePeer]) }

    func client(timestamp: TAI64N = .now(), psk: [UInt8]? = nil) throws -> ClientHandshake {
        var server = macPeer
        if let psk { server.psk = psk }
        return try ClientHandshake(identity: phone, server: server, payload: [phoneHello.message], timestamp: timestamp)
    }

    /// Returns (phone session, mac session, accepted).
    func establish(now: ContinuousClock.Instant = .now) throws -> (SecureSession, SecureSession, HostResponder.Accepted) {
        var r = responder()
        var c = try client()
        let mh = macHello
        let accepted = try r.handleInitiation(c.initiationPacket, now: now) { _ in [mh.message] }
        let (session, messages) = try c.complete(response: accepted.responsePacket, now: now)
        #expect(try messages.map { try Hello($0) } == [macHello])
        return (session, accepted.session, accepted)
    }
}

@Suite("Secure session")
struct SessionTests {
    @Test func handshakeAndBothDirections() throws {
        let p = Pair()
        var (phone, mac, accepted) = try p.establish()
        #expect(accepted.isKnownPeer)
        #expect(try accepted.peerMessages.map { try Hello($0) } == [p.phoneHello])
        #expect(phone.handshakeHash == mac.handshakeHash)
        #expect(phone.localIndex == mac.remoteIndex && mac.localIndex == phone.remoteIndex)
        #expect(mac.peerStaticKey == p.phone.publicKey)
        #expect(phone.isConfirmed)
        #expect(!mac.isConfirmed, "Mac must not stream before the phone proves the PSK")

        let now = ContinuousClock.now
        let up = try phone.seal([1, 2, 3], now: now)
        #expect(SecureSession.receiverIndex(of: up) == mac.localIndex)
        do { let ok = (try mac.open(up, now: now) == [1, 2, 3]); #expect(ok) }
        #expect(mac.isConfirmed)

        let down = try mac.seal(Array("pixels".utf8), now: now)
        do { let ok = (try phone.open(down, now: now) == Array("pixels".utf8)); #expect(ok) }
        #expect(up.count == SecureSession.overhead + 3)
    }

    @Test func outOfOrderWithinWindowAccepted() throws {
        let p = Pair()
        var (phone, mac, _) = try p.establish()
        let now = ContinuousClock.now
        let packets = try (0..<10).map { i in try phone.seal([UInt8(i)], now: now) }
        for i in [3, 0, 9, 1, 2, 8, 4, 5, 7, 6] { do { let ok = (try mac.open(packets[i], now: now) == [UInt8(i)]); #expect(ok) } }
    }

    @Test func replayRejected() throws {
        let p = Pair()
        var (phone, mac, _) = try p.establish()
        let now = ContinuousClock.now
        let pkt = try phone.seal([9], now: now)
        _ = try mac.open(pkt, now: now)
        #expect(throws: SessionError.replayed) { try mac.open(pkt, now: now) }
    }

    @Test func tamperRejected() throws {
        let p = Pair()
        var (phone, mac, _) = try p.establish()
        let now = ContinuousClock.now
        let pkt = try phone.seal([1, 2, 3, 4], now: now)
        for index in [6, 12, 13, pkt.count - 1] {       // counter, counter LSB, ciphertext, tag
            var bad = pkt
            bad[index] ^= 0x01
            #expect(throws: SessionError.decryptFailed) { try mac.open(bad, now: now) }
        }
        var badIndex = pkt
        badIndex[1] ^= 0x80
        #expect(throws: SessionError.wrongReceiver) { try mac.open(badIndex, now: now) }
        #expect(throws: SessionError.malformedPacket) { try mac.open(Array(pkt.prefix(SecureSession.overhead - 1)), now: now) }
        // A rejected tamper must not burn the counter: the genuine packet still opens.
        do { let ok = (try mac.open(pkt, now: now) == [1, 2, 3, 4]); #expect(ok) }
    }

    @Test func ownPacketsDoNotLoopBack() throws {
        let p = Pair()
        var (phone, _, _) = try p.establish()
        let now = ContinuousClock.now
        let pkt = try phone.seal([1], now: now)
        #expect(throws: SessionError.wrongReceiver) { try phone.open(pkt, now: now) }
    }

    @Test func rekeyAndExpiryTimers() throws {
        let p = Pair()
        let t0 = ContinuousClock.now
        var (phone, mac, _) = try p.establish(now: t0)
        #expect(!phone.needsRekey(now: t0 + .seconds(119)))
        #expect(phone.needsRekey(now: t0 + .seconds(120)))
        let late = try phone.seal([1], now: t0 + .seconds(179))
        do { let ok = (try mac.open(late, now: t0 + .seconds(179)) == [1]); #expect(ok) }
        #expect(throws: SessionError.expired) { try phone.seal([1], now: t0 + .seconds(180)) }
        let pkt = try phone.seal([2], now: t0 + .seconds(10))
        #expect(throws: SessionError.expired) { try mac.open(pkt, now: t0 + .seconds(181)) }
    }

    @Test func badMac1IsSilentlyRejected() throws {
        let p = Pair()
        var r = p.responder()
        let c = try p.client()
        var bad = c.initiationPacket
        bad[bad.count - 1] ^= 1
        #expect(throws: SessionError.badMac) { try r.handleInitiation(bad, now: .now) { _ in [] } }
        // A scanner that doesn't know the Mac's public key.
        let noise = [OuterPacketType.handshakeInitiation.rawValue] + [UInt8](repeating: 0x42, count: c.initiationPacket.count - 1)
        #expect(throws: SessionError.badMac) { try r.handleInitiation(noise, now: .now) { _ in [] } }
        #expect(throws: SessionError.malformedPacket) { try r.handleInitiation([0x01, 0, 0], now: .now) { _ in [] } }
    }

    @Test func tamperedResponseRejected() throws {
        let p = Pair()
        var r = p.responder()
        var c = try p.client()
        let a = try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] }
        var bad = a.responsePacket
        bad[20] ^= 1
        #expect(throws: SessionError.badMac) { try c.complete(response: bad, now: .now) }
    }

    @Test func unknownPeerRejected() throws {
        let p = Pair()
        var r = HostResponder(identity: p.mac)
        let c = try p.client()
        #expect(throws: SessionError.unknownPeer) { try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] } }
    }

    @Test func revokedPeerRejected() throws {
        let p = Pair()
        var r = p.responder()
        r.removePeer(publicKey: p.phone.publicKey)
        let c = try p.client()
        #expect(throws: SessionError.unknownPeer) { try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] } }
    }

    @Test func replayedInitiationRejected() throws {
        let p = Pair()
        var r = p.responder()
        let c = try p.client()
        _ = try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] }
        #expect(throws: SessionError.staleTimestamp) { try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] } }
        let older = try p.client(timestamp: TAI64N(date: Date(timeIntervalSinceNow: -60)))
        #expect(throws: SessionError.staleTimestamp) { try r.handleInitiation(older.initiationPacket, now: .now) { _ in [] } }
        let newer = try p.client(timestamp: TAI64N(date: Date(timeIntervalSinceNow: 1)))
        #expect(throws: Never.self) { try r.handleInitiation(newer.initiationPacket, now: .now) { _ in [] } }
    }

    @Test func wrongPSKFailsHandshake() throws {
        let p = Pair()
        var r = p.responder()
        var c = try p.client(psk: DevPairingCode.generatePSK())
        // msg1 doesn't involve the PSK (psk2), so the Mac answers; the phone can't read the answer,
        // and the Mac's session never confirms because the phone never sends an authentic packet.
        let a = try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] }
        #expect(!a.session.isConfirmed)
        #expect(throws: SessionError.handshakeFailed) { try c.complete(response: a.responsePacket, now: .now) }
    }

    @Test func developmentPSKAcceptsNewPhone() throws {
        let p = Pair()
        var r = HostResponder(identity: p.mac, developmentPSK: p.psk)
        var c = try p.client()
        let a = try r.handleInitiation(c.initiationPacket, now: .now) { _ in [] }
        #expect(!a.isKnownPeer)
        var (phone, _) = try c.complete(response: a.responsePacket, now: .now)
        var mac = a.session
        do { let ok = (try mac.open(try phone.seal([7], now: .now), now: .now) == [7]); #expect(ok) }
        #expect(mac.isConfirmed)
    }

    @Test func handshakeFitsOneDatagram() throws {
        let p = Pair()
        let c = try p.client()
        #expect(c.initiationPacket.count < 1200)
    }
}

@Suite("Replay window")
struct ReplayWindowTests {
    @Test func basics() {
        var w = ReplayWindow()
        do { let ok = (w.mark(0)); #expect(ok) }
        do { let ok = (!w.mark(0)); #expect(ok) }
        do { let ok = (w.mark(5)); #expect(ok) }
        do { let ok = (w.mark(3)); #expect(ok) }
        do { let ok = (!w.mark(3)); #expect(ok) }
        do { let ok = (w.mark(4)); #expect(ok) }
    }

    @Test func windowEdge() {
        var w = ReplayWindow()
        do { let ok = (w.mark(10_000)); #expect(ok) }
        #expect(w.canAccept(10_000 - 2047))
        #expect(!w.canAccept(10_000 - 2048))
        do { let ok = (w.mark(10_000 - 2047)); #expect(ok) }
        do { let ok = (!w.mark(10_000 - 2047)); #expect(ok) }
    }

    @Test func slidingClearsOldBits() {
        var w = ReplayWindow()
        for c in UInt64(0)..<3000 { do { let ok = (w.mark(c)); #expect(ok) } }
        for c in UInt64(1000)..<3000 { #expect(!w.canAccept(c)) }
        do { let ok = (w.mark(3000 + 2048 + 5)); #expect(ok) }      // big jump clears everything
        #expect(w.canAccept(3000 + 10))
        #expect(!w.canAccept(2999))
    }

    @Test func randomizedAgainstReference() {
        var g = SystemRandomNumberGenerator()
        var w = ReplayWindow()
        var seen = Set<UInt64>()
        var top: UInt64 = 0
        for _ in 0..<20_000 {
            let c = UInt64.random(in: (top > 3000 ? top - 3000 : 0)...(top + 40), using: &g)
            let expected = !seen.contains(c) && (seen.isEmpty || c > top || top - c < ReplayWindow.size)
            do { let ok = (w.mark(c) == expected); #expect(ok) }
            if expected { seen.insert(c); top = max(top, c) }
        }
    }
}

@Suite("Pairing and timestamps")
struct PairingTests {
    @Test func devCodeRoundTrip() throws {
        let id = StaticIdentity()
        let code = DevPairingCode(macPublicKey: id.publicKey, psk: DevPairingCode.generatePSK())
        #expect(code.string.hasPrefix("CLAMDEV1:"))
        #expect(!code.string.contains("="))
        #expect(DevPairingCode(string: "  " + code.string + "\n") == code)
        #expect(DevPairingCode(string: "CLAMDEV1:abc") == nil)
        #expect(DevPairingCode(string: "nope") == nil)
    }

    @Test func identityRoundTrip() throws {
        let id = StaticIdentity()
        #expect(try StaticIdentity(rawPrivateKey: id.rawPrivateKey).publicKey == id.publicKey)
        #expect(throws: NoiseError.invalidKey) { try StaticIdentity(rawPrivateKey: [1, 2, 3]) }
    }

    @Test func taiOrdering() throws {
        let a = TAI64N(date: Date(timeIntervalSince1970: 1_000))
        let b = TAI64N(date: Date(timeIntervalSince1970: 1_000.5))
        let c = TAI64N(date: Date(timeIntervalSince1970: 1_001))
        #expect(a < b && b < c)
        #expect(a.bytes.count == 12)
        #expect(a.bytes[0] == 0x40)
        #expect(throws: NoiseError.self) { try TAI64N(bytes: [0]) }
    }

    @Test func indicesNonZero() {
        for _ in 0..<1000 { #expect(HandshakePacket.randomIndex() != 0) }
    }
}
