import Foundation
import Testing
import ClamshellSession
import ClamshellWire
@testable import ClamshellTransport

@Suite("Coalescing")
struct CoalesceTests {
    @Test func packsAndSplits() {
        let small = Ping(id: 1, t1: 1).message
        let size = small.encoded.count
        let out = coalesce(Array(repeating: small, count: 10), maxPayload: size * 4)
        #expect(out.map(\.count) == [size * 4, size * 4, size * 2])
        let big = InnerMessage(channel: .video, type: .videoFragment, body: [UInt8](repeating: 0, count: 500))
        #expect(coalesce([small, big, small], maxPayload: 100).count == 3, "oversized message gets its own payload")
        #expect(coalesce([], maxPayload: 100).isEmpty)
    }
}

/// Real UDP over loopback: handshake, confirmation, both directions, rejection of a wrong PSK.
@Suite("UDP loopback", .serialized, .timeLimit(.minutes(1)))
struct LoopbackTests {
    let mac = StaticIdentity()
    let phone = StaticIdentity()
    let psk = DevPairingCode.generatePSK()
    let macHello = Hello(appVersion: "test", build: 1, capabilities: [.hevc444Decode, .ltr], deviceName: "Mac")
    let phoneHello = Hello(appVersion: "test", build: 1, capabilities: [.hevc444Decode], displayModes: [.laptop], deviceName: "Duo")

    /// Drains a single-consumer stream into a log that tests can wait on.
    actor Log<E: Sendable> {
        private(set) var items: [E] = []
        func append(_ e: E) { items.append(e) }
        func first(timeout: Duration = .seconds(3), where match: @Sendable (E) -> Bool) async -> E? {
            let deadline = ContinuousClock.now + timeout
            while ContinuousClock.now < deadline {
                if let e = items.first(where: match) { return e }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return nil
        }
    }

    func log<S: AsyncSequence & Sendable>(_ s: S) -> Log<S.Element> where S.Element: Sendable {
        let l = Log<S.Element>()
        _ = Task { () async throws -> Void in for try await e in s { await l.append(e) } }
        return l
    }

    @Test func handshakeAndMessages() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac, developmentPSK: psk), hello: macHello)
        let port = try await server.start(port: nil, bonjourName: nil)
        #expect(port != 0)

        let events = log(server.events)
        let client = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone,
                                             server: PeerConfig(publicKey: mac.publicKey, psk: psk, name: "Mac"), hello: phoneHello)
        let started = ContinuousClock.now
        let got = try await client.connect(timeout: .seconds(3))
        #expect(got == macHello)

        let connected = await events.first { if case .peerConnected = $0 { true } else { false } }
        guard case .peerConnected(let key, let hello, let negotiation, let known)? = connected else {
            Issue.record("no peerConnected"); return
        }
        let elapsed = ContinuousClock.now - started
        #expect(key == phone.publicKey && hello == phoneHello && !known)
        #expect(negotiation == .compatible(minor: ProtocolVersion.minor, capabilities: [.hevc444Decode]))
        #expect(elapsed < .milliseconds(500), "LAN handshake took \(elapsed)")

        // Mac → phone.
        let inbox = log(client.messages)
        await server.send([Pong(id: 9, t1: 1, t2: 2, t3: 3).message], to: phone.publicKey)
        let batch = await inbox.first { $0.contains { $0.type == .pong } } ?? []
        #expect(batch.compactMap { try? Pong($0) }.first == Pong(id: 9, t1: 1, t2: 2, t3: 3))

        // Phone → Mac.
        await client.send([KeyframeRequest(reason: .sessionStart, lastGoodFrameId: 0).message])
        let got2 = await events.first { e in
            if case .messages(_, let m) = e { return m.contains { $0.type == .keyframeRequest } }
            return false
        }
        guard case .messages(_, let msgs)? = got2 else { Issue.record("no messages"); return }
        #expect(try KeyframeRequest(msgs[0]) == KeyframeRequest(reason: .sessionStart, lastGoodFrameId: 0))

        await client.close()
        await server.stop()
    }

    /// A phone that goes silent (killed, out of coverage) is dropped after the idle timeout, not after 180 s.
    @Test func silentPhoneIsDropped() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac, developmentPSK: psk), hello: macHello,
                                       idleTimeout: .seconds(1))
        let port = try await server.start(port: nil, bonjourName: nil)
        let events = log(server.events)
        let client = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone,
                                             server: PeerConfig(publicKey: mac.publicKey, psk: psk, name: "Mac"), hello: phoneHello)
        _ = try await client.connect(timeout: .seconds(3))
        #expect(await events.first { if case .peerConnected = $0 { true } else { false } } != nil)
        let started = ContinuousClock.now
        let gone = await events.first(timeout: .seconds(5)) { if case .peerDisconnected = $0 { true } else { false } }
        #expect(gone != nil)
        #expect(ContinuousClock.now - started < .seconds(3))
        await client.close()
        await server.stop()
    }

    /// Real pairing over loopback UDP, then a normal session with the keys it produced; no dev PSK anywhere.
    @Test func pairThenConnect() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac), hello: macHello)
        let port = try await server.start(port: nil, bonjourName: nil)
        let invite = PairingInvite(macPublicKey: mac.publicKey, secret: PairingInvite.newSecret(), macName: "Mac", port: port)
        await server.openPairing(invite)
        let events = log(server.events)
        let confirmer = Task {
            guard case .pairingRequest(let r)? = await events.first(timeout: .seconds(5), where: { if case .pairingRequest = $0 { true } else { false } }) else { return "" }
            _ = try await server.confirmPairing(r.id, accept: PairingAccept(accepted: true, udpPort: port, tcpPort: 443))
            return r.sas
        }
        let shown = LockedBox("")
        let (macPeer, endpoint) = try await PairingClient.pair(path: UDPClient(host: "127.0.0.1", port: port), identity: phone,
                                                               invite: invite, phoneName: "Duo", timeout: .seconds(5)) { shown.set($0) }
        #expect(try await confirmer.value == shown.get())
        #expect(macPeer.publicKey == mac.publicKey && endpoint.udpPort == port)

        let client = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone, server: macPeer, hello: phoneHello)
        _ = try await client.connect(timeout: .seconds(3))
        let connected = await events.first { if case .peerConnected = $0 { true } else { false } }
        guard case .peerConnected(_, _, _, let known)? = connected else { Issue.record("no session"); return }
        #expect(known)
        // Pause drops the session and refuses new handshakes.
        await server.setPaused(true)
        #expect(await events.first { if case .peerDisconnected = $0 { true } else { false } } != nil)
        let again = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone, server: macPeer, hello: phoneHello)
        await #expect(throws: ClientSessionConnection.ConnectError.timedOut) { _ = try await again.connect(timeout: .milliseconds(600)) }
        await client.close(); await again.close()
        await server.stop()
    }

    /// The phone reconnects (the app relaunched, the network changed) before the Mac noticed the old connection
    /// died. A new connection id is a new session for the host; before 1.7 it looked like a rekey, so the host
    /// kept the old input numbering (and dropped the phone's new input as duplicates) and never re-sent the
    /// cursor shape, which left the phone with no pointer.
    @Test func reconnectIsANewSessionNotARekey() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac, developmentPSK: psk), hello: macHello)
        let port = try await server.start(port: nil, bonjourName: nil)
        let events = log(server.events)
        let peer = PeerConfig(publicKey: mac.publicKey, psk: psk, name: "Mac")
        var first = phoneHello; first.connectionId = 1
        var second = phoneHello; second.connectionId = 2
        let a = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone, server: peer, hello: first)
        _ = try await a.connect(timeout: .seconds(3))
        // No close: the old connection just stops, as when iOS suspends the app.
        let b = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone, server: peer, hello: second)
        _ = try await b.connect(timeout: .seconds(3))
        let fresh = await events.first { if case .peerConnected(_, let h, _, _) = $0 { h.connectionId == 2 } else { false } }
        #expect(fresh != nil, "the reconnect must start a new session")
        await a.close(); await b.close()
        await server.stop()
    }

    /// Same connection id (a rekey), or phones without one: the running session carries on, as before 1.7.
    @Test func rekeyKeepsTheSession() {
        var h = phoneHello
        #expect(HostSessionServer.isRekey(old: h, new: h))                   // no ids: an older phone
        h.connectionId = 7
        var other = h; other.connectionId = 8
        #expect(HostSessionServer.isRekey(old: h, new: h))
        #expect(!HostSessionServer.isRekey(old: h, new: other))
        #expect(!HostSessionServer.isRekey(old: nil, new: h))                // the old session already expired
        #expect(!HostSessionServer.isRekey(old: phoneHello, new: h))         // an updated phone after an old one
    }

    @Test func wrongPSKTimesOut() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac, developmentPSK: psk), hello: macHello)
        let port = try await server.start(port: nil, bonjourName: nil)
        let client = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone,
                                             server: PeerConfig(publicKey: mac.publicKey, psk: DevPairingCode.generatePSK(), name: "Mac"),
                                             hello: phoneHello)
        await #expect(throws: ClientSessionConnection.ConnectError.timedOut) { try await client.connect(timeout: .seconds(1)) }
        await client.close()
        await server.stop()
    }

    @Test func wrongServerKeyIsIgnored() async throws {
        let server = HostSessionServer(responder: HostResponder(identity: mac, developmentPSK: psk), hello: macHello)
        let port = try await server.start(port: nil, bonjourName: nil)
        let client = ClientSessionConnection(udp: UDPClient(host: "127.0.0.1", port: port), identity: phone,
                                             server: PeerConfig(publicKey: StaticIdentity().publicKey, psk: psk, name: "Impostor"),
                                             hello: phoneHello)
        await #expect(throws: ClientSessionConnection.ConnectError.timedOut) { try await client.connect(timeout: .seconds(1)) }
        #expect(await server.droppedPackets > 0, "mac1 mismatch must be dropped silently")
        await client.close()
        await server.stop()
    }
}

final class LockedBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
}
