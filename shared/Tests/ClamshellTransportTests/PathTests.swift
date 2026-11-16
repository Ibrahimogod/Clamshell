@preconcurrency import Security
import Foundation
import Synchronization
import Testing
import ClamshellSession
import ClamshellWire
@testable import ClamshellTransport

/// P3 and the path race over loopback (ADR-0002): a real TLS + WebSocket listener with a self-signed identity.
@Suite("Paths: WSS and racing", .serialized, .timeLimit(.minutes(1)))
struct PathTests {
    /// One consumer per connection's message stream.
    actor Inboxes {
        var logs: [ObjectIdentifier: LoopbackTests.Log<[InnerMessage]>] = [:]
        func log(_ c: ClientSessionConnection) -> LoopbackTests.Log<[InnerMessage]> {
            if let l = logs[ObjectIdentifier(c)] { return l }
            let l = LoopbackTests.Log<[InnerMessage]>()
            Task { for await m in c.messages { await l.append(m) } }
            logs[ObjectIdentifier(c)] = l
            return l
        }
    }
    static let inboxes = Inboxes()

    let base = LoopbackTests()

    nonisolated(unsafe) static let identity: SecIdentity? = {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clamshell-edge-test")
        return try? EdgeIdentity.loadOrCreate(directory: dir)
    }()

    struct Rig {
        let server: HostSessionServer
        let wss: WSSServer
        let udpPort: UInt16
        let wssPort: UInt16
        let events: LoopbackTests.Log<HostSessionServer.Event>
        func inbox(_ c: ClientSessionConnection) async -> LoopbackTests.Log<[InnerMessage]> { await PathTests.inboxes.log(c) }
    }

    func rig() async throws -> Rig {
        let id = try #require(Self.identity, "self-signed identity via /usr/bin/openssl")
        let server = HostSessionServer(responder: HostResponder(identity: base.mac, developmentPSK: base.psk), hello: base.macHello)
        let udpPort = try await server.start(port: nil, bonjourName: nil)
        let wss = WSSServer()
        let wssPort = try await wss.start(port: 0, identity: id)
        await server.attach(wss.datagrams)
        // One consumer for the server's events; like the real host, it answers every Ping with a Pong.
        let events = LoopbackTests.Log<HostSessionServer.Event>()
        let phoneKey = base.phone.publicKey
        Task {
            for await e in server.events {
                await events.append(e)
                if case .messages(_, let m) = e {
                    for p in m.compactMap({ try? Ping($0) }) { await server.send([Pong(id: p.id, t1: p.t1, t2: 2, t3: 3).message], to: phoneKey) }
                }
            }
        }
        return Rig(server: server, wss: wss, udpPort: udpPort, wssPort: wssPort, events: events)
    }

    func client(_ path: any PacketPath) -> ClientSessionConnection {
        ClientSessionConnection(udp: path, identity: base.phone, server: PeerConfig(publicKey: base.mac.publicKey, psk: base.psk, name: "Mac"),
                                hello: base.phoneHello)
    }

    /// Phone → Mac → phone round trip on whatever path the connection uses.
    func roundTrip(_ r: Rig, _ c: ClientSessionConnection, id: UInt32) async -> Bool {
        let inbox = await r.inbox(c)
        await c.send([Ping(id: id, t1: 1).message])
        return await inbox.first { $0.contains { (try? Pong($0))?.id == id } } != nil
    }

    @Test func wssAlone() async throws {
        let r = try await rig()
        let c = client(WSSClient(host: "127.0.0.1", port: r.wssPort))
        let hello = try await c.connect(timeout: .seconds(3))
        #expect(hello == base.macHello)
        #expect(await roundTrip(r, c, id: 5))
        #expect(await r.server.pathKind(of: base.phone.publicKey) == "wss")
        await c.close(); await r.server.stop(); r.wss.stop()
    }

    @Test func udpBlockedFallsToWSS() async throws {
        let r = try await rig()
        let racer = PathRacer([
            .init(rank: 1, delay: .zero) { UDPClient(host: "127.0.0.1", port: 9, name: "udp") },     // nothing listens there
            .init(rank: 2, delay: .milliseconds(150)) { WSSClient(host: "127.0.0.1", port: r.wssPort) },
        ])
        let c = client(racer)
        let started = ContinuousClock.now
        _ = try await c.connect(timeout: .seconds(3))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await roundTrip(r, c, id: 6))
        #expect(racer.activeName == "wss")
        await c.close(); await r.server.stop(); r.wss.stop()
    }

    @Test func udpWinsWhenBothWork() async throws {
        let r = try await rig()
        let racer = PathRacer([
            .init(rank: 1, delay: .zero) { UDPClient(host: "127.0.0.1", port: r.udpPort, name: "udp") },
            .init(rank: 2, delay: .milliseconds(150)) { WSSClient(host: "127.0.0.1", port: r.wssPort) },
        ])
        let c = client(racer)
        _ = try await c.connect(timeout: .seconds(3))
        #expect(await roundTrip(r, c, id: 7))
        #expect(racer.activeName == "udp")
        #expect(await r.server.pathKind(of: base.phone.publicKey) == "udp")
        await c.close(); await r.server.stop(); r.wss.stop()
    }

    /// UDP goes dark mid-session (a firewall starts dropping it): traffic moves to WSS without a new handshake.
    @Test func udpBlockedMidStreamMovesToWSS() async throws {
        let r = try await rig()
        let blocked = Blockable(UDPClient(host: "127.0.0.1", port: r.udpPort, name: "udp"))
        let racer = PathRacer([
            .init(rank: 1, delay: .zero) { blocked },
            .init(rank: 2, delay: .milliseconds(150)) { WSSClient(host: "127.0.0.1", port: r.wssPort) },
        ])
        let c = client(racer)
        _ = try await c.connect(timeout: .seconds(3))
        try await Task.sleep(for: .milliseconds(300))              // let WSS come up too
        #expect(await roundTrip(r, c, id: 8))
        #expect(racer.activeName == "udp")
        blocked.blocked.withLock { $0 = true }
        let cut = ContinuousClock.now
        // The app pings at 10 Hz; keep traffic flowing until the racer notices.
        let pinger = Task { while !Task.isCancelled { await c.send([Ping(id: 99, t1: 1).message]); try? await Task.sleep(for: .milliseconds(100)) } }
        while racer.activeName != "wss", ContinuousClock.now - cut < .seconds(3) { try await Task.sleep(for: .milliseconds(20)) }
        let moved = ContinuousClock.now - cut
        pinger.cancel()
        #expect(racer.activeName == "wss")
        #expect(moved < .seconds(1), "moved after \(moved)")
        #expect(await roundTrip(r, c, id: 10))
        await c.close(); await r.server.stop(); r.wss.stop()
    }

    @Test func wssRejectsGarbage() async throws {
        let r = try await rig()
        let w = WSSClient(host: "127.0.0.1", port: r.wssPort)
        try await w.start()
        w.send([[0x01, 0x02, 0x03], [UInt8](repeating: 0xAB, count: 200)])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await r.server.droppedPackets >= 2, "unauthenticated packets dropped silently")
        w.stop(); await r.server.stop(); r.wss.stop()
    }
}

/// A path that can be cut: drops everything both ways while `blocked`.
final class Blockable: PacketPath, @unchecked Sendable {
    let inner: any PacketPath
    let blocked = Mutex(false)
    let datagrams: AsyncStream<[UInt8]>
    private let cont: AsyncStream<[UInt8]>.Continuation
    var name: String { inner.name }
    init(_ inner: any PacketPath) {
        self.inner = inner
        (datagrams, cont) = AsyncStream.makeStream(of: [UInt8].self)
    }
    func start() async throws {
        try await inner.start()
        let s = inner.datagrams, c = cont
        Task { [self] in for await d in s where !self.blocked.withLock({ $0 }) { c.yield(d) }; c.finish() }
    }
    func send(_ packets: [[UInt8]]) { if !blocked.withLock({ $0 }) { inner.send(packets) } }
    func stop() { inner.stop() }
}
