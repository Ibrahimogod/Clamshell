import ClamshellSession
import ClamshellWire
import Dispatch

/// Largest UDP datagram we send. Conservative for Wi-Fi/VPN/IPv6 paths; LAN-only tuning in M3.
public let clamshellMaxDatagram = 1200

/// Packs inner messages into as few transport payloads as possible, each ≤ `maxPayload`.
/// A message larger than `maxPayload` gets a payload of its own.
public func coalesce(_ messages: [InnerMessage], maxPayload: Int) -> [[UInt8]] {
    var out: [[UInt8]] = []
    var current = ByteWriter(capacity: maxPayload)
    for m in messages {
        let encoded = m.encoded
        if !current.bytes.isEmpty && current.bytes.count + encoded.count > maxPayload {
            out.append(current.bytes)
            current = ByteWriter(capacity: maxPayload)
        }
        current.raw(encoded)
    }
    if !current.bytes.isEmpty { out.append(current.bytes) }
    return out
}

/// Mac side: accepts handshakes, keeps one current session per paired phone, routes transport
/// packets by receiver index, follows the phone to new addresses (roaming).
public actor HostSessionServer {
    public enum Event: Sendable {
        case peerConnected(peerKey: [UInt8], hello: Hello, negotiation: Negotiation, knownPeer: Bool)
        case messages(peerKey: [UInt8], [InnerMessage])
        case peerDisconnected(peerKey: [UInt8])
        /// A phone finished the pairing handshake; show its SAS and ask (ADR-0014).
        case pairingRequest(PairingWindow.Request)
        /// The pairing window closed (time out, or three failed attempts).
        case pairingClosed
    }

    private struct Live {
        var session: SecureSession
        var remote: any PacketRemote
        var hello: Hello
        var negotiation: Negotiation
        var known: Bool
        /// Last authentic packet from a local-network address (the phone's LAN path).
        var lastLocal: ContinuousClock.Instant?
    }

    /// While the phone is heard on the LAN this recently, packets on other paths don't move its replies off it.
    static let localStickiness: Duration = .milliseconds(500)

    /// A connected phone pings at least once a second, so this much silence means it's gone (app killed, out of
    /// coverage). Without it the Mac would keep streaming into nothing until the session keys expire (180 s).
    public let idleTimeout: Duration
    private var lastHeard: [[UInt8]: ContinuousClock.Instant] = [:]

    private let udp = UDPServer()
    private var responder: HostResponder
    private let localHello: Hello
    private var sessions: [UInt32: Live] = [:]
    private var current: [[UInt8]: UInt32] = [:]
    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    public private(set) var droppedPackets = 0
    private var limiter = HandshakeLimiter(nowNs: UInt64(DispatchTime.now().uptimeNanoseconds))
    /// The UDP port `start` bound, once started.
    public private(set) var boundPort: UInt16?
    private var pairing: PairingWindow?
    private var pairingRemotes: [UInt32: any PacketRemote] = [:]
    /// Remote access paused: no handshakes or sessions are served (LAN pairing still is).
    public private(set) var paused = false

    public init(responder: HostResponder, hello: Hello, idleTimeout: Duration = .seconds(10)) {
        self.responder = responder
        self.idleTimeout = idleTimeout
        self.localHello = hello
        (events, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .bufferingNewest(1024))
    }

    /// Binds and starts serving; returns the bound port.
    public func start(port: UInt16?, bonjourName: String?) async throws -> UInt16 {
        let p = try await udp.start(port: port, bonjourName: bonjourName)
        boundPort = p
        let stream = udp.datagrams
        Task { [weak self] in
            for await d in stream { await self?.handle(d) }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.expireSessions()
            }
        }
        return p
    }

    /// Another packet source (the WSS listener on 443): handled exactly like UDP datagrams.
    public func attach(_ stream: AsyncStream<UDPServer.Datagram>) {
        Task { [weak self] in
            for await d in stream { await self?.handle(d) }
        }
    }

    /// Whether a peer's current path comes from this network (private, link-local or loopback address).
    /// False for the internet, including the 443 edge; nil without a session.
    /// "udp 1.2.3.4" or "wss …", for the host log.
    public func pathDescription(of peerKey: [UInt8]) -> String? {
        current[peerKey].flatMap { sessions[$0].map { "\($0.remote.kind) \($0.remote.sourceHost)" } }
    }

    /// The peer's source address without the port.
    public func sourceHost(of peerKey: [UInt8]) -> String? {
        current[peerKey].flatMap { sessions[$0]?.remote.sourceHost }
    }

    public func isLocalPath(of peerKey: [UInt8]) -> Bool? {
        current[peerKey].flatMap { sessions[$0]?.remote.isLocalNetwork }
    }

    /// The kind of path ("udp", "wss") a peer's session currently uses.
    public func pathKind(of peerKey: [UInt8]) -> String? {
        current[peerKey].flatMap { sessions[$0]?.remote.kind }
    }

    public func stop() {
        for (_, idx) in current { if let l = sessions[idx] { sendGoodbye(l) } }
        udp.stop()
        continuation.finish()
    }

    public func addPeer(_ peer: PeerConfig) { responder.addPeer(peer) }

    public var publicKey: [UInt8] { responder.identity.publicKey }

    // MARK: pairing (ADR-0014)

    public func openPairing(_ invite: PairingInvite, duration: Duration = .seconds(120)) {
        pairing = PairingWindow(identity: responder.identity, invite: invite, now: .now, duration: duration)
        pairingRemotes = [:]
    }

    public func closePairing() {
        pairing = nil
        pairingRemotes = [:]
    }

    public var pairingOpen: Bool { pairing.map { !$0.isClosed && ContinuousClock.now < $0.deadline } ?? false }

    /// The person confirmed the SAS: store the peer, tell the phone. The window stays open for repeats.
    public func confirmPairing(_ id: UInt32, accept: PairingAccept) throws -> PeerConfig {
        guard var w = pairing else { throw PairingError.closed }
        let (packet, peer) = try w.confirm(id, accept: accept)
        pairing = w
        responder.addPeer(peer)
        pairingRemotes[id]?.send([packet])
        return peer
    }

    public func rejectPairing(_ id: UInt32) {
        guard var w = pairing else { return }
        if let packet = w.reject(id) { pairingRemotes[id]?.send([packet]) }
        pairing = w
    }

    private func handlePairing(_ d: UDPServer.Datagram) {
        guard var w = pairing, d.from.isLocalNetwork, d.bytes.count >= 8 else { droppedPackets += 1; return }
        let id = UInt32(d.bytes[4]) << 24 | UInt32(d.bytes[5]) << 16 | UInt32(d.bytes[6]) << 8 | UInt32(d.bytes[7])
        let out = w.handle(d.bytes, now: .now)
        pairing = w
        switch out {
        case .none: droppedPackets += 1
        case .reply(let p):
            pairingRemotes[id] = d.from
            d.from.send([p])
        case .request(let r):
            pairingRemotes[id] = d.from
            continuation.yield(.pairingRequest(r))
        case .closed:
            pairing = nil
            continuation.yield(.pairingClosed)
        }
    }

    /// Pause remote access: drop every live session and answer nothing but LAN pairing until resumed.
    public func setPaused(_ on: Bool) {
        paused = on
        if on { disconnectAll() }
    }

    /// Ends every live session; pairings stay.
    public func disconnectAll() {
        for (_, idx) in current { if let l = sessions[idx] { sendGoodbye(l) } }
        for key in current.keys { continuation.yield(.peerDisconnected(peerKey: key)) }
        sessions = [:]
        current = [:]
    }

    public func revoke(peerKey: [UInt8]) {
        responder.removePeer(publicKey: peerKey)
        for (idx, l) in sessions where l.session.peerStaticKey == peerKey {
            sendGoodbye(l)
            sessions[idx] = nil
        }
        if current.removeValue(forKey: peerKey) != nil { continuation.yield(.peerDisconnected(peerKey: peerKey)) }
    }

    /// Sends messages to the peer's current confirmed session, coalesced into datagrams.
    public func send(_ messages: [InnerMessage], to peerKey: [UInt8]) {
        let maxPayload = clamshellMaxDatagram - SecureSession.overhead
        sendPayloads(coalesce(messages, maxPayload: maxPayload), to: peerKey)
    }

    /// One payload per datagram (used for video fragments sized to fit exactly).
    public func sendPayloads(_ payloads: [[UInt8]], to peerKey: [UInt8]) {
        guard let idx = current[peerKey], var live = sessions[idx], live.session.isConfirmed else { return }
        let now = ContinuousClock.now
        var packets: [[UInt8]] = []
        packets.reserveCapacity(payloads.count)
        for p in payloads {
            guard let packet = try? live.session.seal(p, now: now) else { break }
            packets.append(packet)
        }
        sessions[idx] = live
        live.remote.send(packets)
    }

    private func sendGoodbye(_ l: Live) {
        var l = l
        if let p = try? l.session.seal(Goodbye(reason: .shuttingDown).message.encoded, now: .now) { l.remote.send([p]) }
    }

    private func handle(_ d: UDPServer.Datagram) {
        guard let first = d.bytes.first else { return }
        switch OuterPacketType(rawValue: first) {
        case .handshakeInitiation where !paused: handleInitiation(d)
        case .transport where !paused: handleTransport(d)
        case .pairing: handlePairing(d)
        default: droppedPackets += 1   // silent: never answer unknown packets
        }
    }

    private func handleInitiation(_ d: UDPServer.Datagram) {
        guard limiter.allow(host: d.from.sourceHost, nowNs: UInt64(DispatchTime.now().uptimeNanoseconds)) else {
            droppedPackets += 1
            return
        }
        let local = localHello
        var negotiated: Negotiation = .compatible(minor: 0, capabilities: [])
        var peerHello: Hello?
        let accepted: HostResponder.Accepted
        do {
            accepted = try responder.handleInitiation(d.bytes, now: .now) { msgs in
                guard let h = msgs.first(where: { $0.type == .hello }).flatMap({ try? Hello($0) }) else { return [local.message] }
                peerHello = h
                negotiated = Negotiation.negotiate(mac: local, phone: h)
                if case .incompatible(let inc) = negotiated { return [local.message, inc.message] }
                return [local.message]
            }
        } catch {
            droppedPackets += 1
            return
        }
        guard let peerHello else { droppedPackets += 1; return }
        sessions[accepted.session.localIndex] = Live(session: accepted.session, remote: d.from, hello: peerHello,
                                                     negotiation: negotiated, known: accepted.isKnownPeer)
        d.from.send([accepted.responsePacket])
    }

    private func handleTransport(_ d: UDPServer.Datagram) {
        guard let idx = SecureSession.receiverIndex(of: d.bytes), var live = sessions[idx] else { droppedPackets += 1; return }
        let wasConfirmed = live.session.isConfirmed
        let payload: [UInt8]
        do { payload = try live.session.open(d.bytes, now: .now) } catch { droppedPackets += 1; return }
        // Roaming: follow the latest authentic address, except off a LAN address that's still in use. A phone
        // that connected by the home address is heard on the LAN and through the router at once while its paths
        // race or probe, and following each packet bounced the video between the two (reordered → keyframes).
        let now = ContinuousClock.now
        if d.from.isLocalNetwork {
            live.lastLocal = now
            live.remote = d.from
        } else if !live.remote.isLocalNetwork || live.lastLocal.map({ now - $0 > Self.localStickiness }) ?? true {
            live.remote = d.from
        }
        sessions[idx] = live
        let key = live.session.peerStaticKey
        lastHeard[key] = .now
        if !wasConfirmed {
            let previous = current[key]
            current[key] = idx
            if let previous, previous != idx, Self.isRekey(old: sessions[previous]?.hello, new: live.hello) {
                // Rekey: the old session keeps decrypting until it expires.
            } else {
                // A new connection from this phone (or its first): the old one, if any, is gone on the phone,
                // and the host must start afresh (input numbering, cursor shape, stream) instead of carrying on.
                if let previous, previous != idx { sessions[previous] = nil }
                continuation.yield(.peerConnected(peerKey: key, hello: live.hello, negotiation: live.negotiation, knownPeer: live.known))
            }
        }
        guard let messages = try? InnerMessage.decodeAll(payload), !messages.isEmpty else { return }
        continuation.yield(.messages(peerKey: key, messages))
    }

    /// A handshake from a phone that already has a session is a rekey of it when it carries the same
    /// connection id (1.7). Phones before 1.7 send none, and every such handshake counts as a rekey, as before.
    static func isRekey(old: Hello?, new: Hello) -> Bool {
        guard let id = new.connectionId else { return old?.connectionId == nil }
        return old?.connectionId == id
    }

    private func expireSessions() {
        let now = ContinuousClock.now
        for (key, idx) in current where now - (lastHeard[key] ?? now) > idleTimeout {
            if let l = sessions[idx] { sendGoodbye(l) }    // in case only the phone's side of the path died
            for (i, l) in sessions where l.session.peerStaticKey == key { sessions[i] = nil }
            current[key] = nil
            lastHeard[key] = nil
            continuation.yield(.peerDisconnected(peerKey: key))
        }
        for (idx, l) in sessions where l.session.isExpired(now: now) || (!l.session.isConfirmed && l.session.age(now: now) > .seconds(10)) {
            sessions[idx] = nil
            let key = l.session.peerStaticKey
            if current[key] == idx {
                current[key] = nil
                continuation.yield(.peerDisconnected(peerKey: key))
            }
        }
    }
}

/// Phone side: handshake with retry, transparent rekey every 120 s, send/receive inner messages.
public actor ClientSessionConnection {
    public enum ConnectError: Error, Equatable, Sendable { case timedOut, incompatible(Incompatible), rejected }

    private let udp: any PacketPath
    private let identity: StaticIdentity
    private let server: PeerConfig
    private let hello: Hello
    private var session: SecureSession?
    private var previous: SecureSession?
    /// Handshakes sent and not answered yet, newest last. The connect loop sends a fresh one every 500 ms, and
    /// on a slow path (mobile data, a router that just restarted) the Mac's answer to one comes back after the
    /// next has gone out: an answer to any of them completes the handshake.
    private var pending: [ClientHandshake] = []
    static let maxPending = 16
    private var serverHello: Hello?
    private var waiters: [CheckedContinuation<Hello, Error>] = []
    private var rekeyStarted: ContinuousClock.Instant?
    public nonisolated let messages: AsyncStream<[InnerMessage]>
    private let continuation: AsyncStream<[InnerMessage]>.Continuation
    public private(set) var droppedPackets = 0
    /// Handshake answers from the Mac that matched none of ours (a failed connect: answers did arrive).
    public private(set) var unmatchedAnswers = 0
    public private(set) var handshakesSent = 0

    public init(udp: any PacketPath, identity: StaticIdentity, server: PeerConfig, hello: Hello) {
        self.udp = udp
        self.identity = identity
        self.server = server
        self.hello = hello
        (messages, continuation) = AsyncStream.makeStream(of: [InnerMessage].self, bufferingPolicy: .bufferingNewest(1024))
    }

    /// Starts the socket, performs the handshake (retrying every 500 ms), returns the Mac's Hello.
    public func connect(timeout: Duration = .seconds(5)) async throws -> Hello {
        try await udp.start()
        let stream = udp.datagrams
        Task { [weak self] in
            for await d in stream { await self?.handle(d) }
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.maintenance()
            }
        }
        let deadline = ContinuousClock.now + timeout
        Task { [weak self] in
            while ContinuousClock.now < deadline {
                guard let self, await self.serverHello == nil else { return }
                await self.sendInitiation()
                try? await Task.sleep(for: .milliseconds(500))
            }
            await self?.failWaiters(ConnectError.timedOut)
        }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    public var currentSession: SecureSession? { session }

    public func send(_ messages: [InnerMessage]) {
        guard var s = session else { return }
        let payloads = coalesce(messages, maxPayload: clamshellMaxDatagram - SecureSession.overhead)
        var packets: [[UInt8]] = []
        for p in payloads {
            guard let packet = try? s.seal(p, now: .now) else { break }
            packets.append(packet)
        }
        session = s
        udp.send(packets)
    }

    public func close() {
        send([Goodbye(reason: .userDisconnected).message])
        udp.stop()
        continuation.finish()
    }

    private func sendInitiation() {
        do {
            let hs = try ClientHandshake(identity: identity, server: server, payload: [hello.message])
            pending.append(hs)
            handshakesSent += 1
            if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
            udp.send([hs.initiationPacket])
        } catch {
            failWaiters(ConnectError.rejected)
        }
    }

    private func failWaiters(_ e: Error) {
        let w = waiters
        waiters = []
        for k in w { k.resume(throwing: e) }
    }

    private func handle(_ bytes: [UInt8]) {
        guard let first = bytes.first else { return }
        switch OuterPacketType(rawValue: first) {
        case .handshakeResponse:
            var completed: (session: SecureSession, messages: [InnerMessage])?
            for i in pending.indices.reversed() {
                var hs = pending[i]
                if let r = try? hs.complete(response: bytes, now: .now) { completed = r; break }
            }
            guard let result = completed else { droppedPackets += 1; unmatchedAnswers += 1; return }
            pending = []
            rekeyStarted = nil
            previous = session
            session = result.session
            let macHello = result.messages.first(where: { $0.type == .hello }).flatMap { try? Hello($0) }
            let incompatible = result.messages.first(where: { $0.type == .incompatible }).flatMap { try? Incompatible($0) }
            // Confirm the session right away: proves we hold the PSK and lets the Mac start streaming.
            send([Ping(id: Ping.keepaliveId, t1: ContinuousClock.now.nanosecondsSinceReference).message])
            if serverHello == nil {
                serverHello = macHello
                let w = waiters
                waiters = []
                for k in w {
                    if let incompatible { k.resume(throwing: ConnectError.incompatible(incompatible)) }
                    else if let macHello { k.resume(returning: macHello) }
                    else { k.resume(throwing: ConnectError.rejected) }
                }
            }
        case .transport:
            guard let idx = SecureSession.receiverIndex(of: bytes) else { droppedPackets += 1; return }
            var payload: [UInt8]?
            if var s = session, s.localIndex == idx {
                payload = try? s.open(bytes, now: .now)
                session = s
            } else if var s = previous, s.localIndex == idx {
                payload = try? s.open(bytes, now: .now)
                previous = s
            }
            guard let payload, let msgs = try? InnerMessage.decodeAll(payload) else { droppedPackets += 1; return }
            if !msgs.isEmpty { continuation.yield(msgs) }
        default:
            droppedPackets += 1
        }
    }

    private func maintenance() {
        let now = ContinuousClock.now
        if let p = previous, p.isExpired(now: now) { previous = nil }
        guard let s = session, serverHello != nil else { return }
        if s.needsRekey(now: now), rekeyStarted.map({ now - $0 > .seconds(5) }) ?? true {
            rekeyStarted = now
            sendInitiation()
        }
    }
}

extension ContinuousClock.Instant {
    /// Monotonic nanoseconds since an arbitrary per-boot reference; only differences are meaningful.
    public var nanosecondsSinceReference: UInt64 {
        let d = self - ContinuousClock.Instant.reference
        let (s, atto) = d.components
        return UInt64(max(0, s)) &* 1_000_000_000 &+ UInt64(max(0, atto) / 1_000_000_000)
    }

    static let reference = ContinuousClock.now - .seconds(1)
}
