import Foundation
import Network
import Security
import Synchronization

/// Path P3 (ADR-0002/0003): our Noise packets, one per binary WebSocket message, inside TLS 1.3 on TCP 443.
/// The outer TLS is camouflage only; the Noise session inside authenticates both sides.

/// One phone connected over WebSocket, as the Mac sees it.
final class WSSRemote: PacketRemote {
    let connection: NWConnection
    /// Bytes handed to the socket and not yet written: above `maxQueued` new packets are dropped (video
    /// recovers with a keyframe), so a slow TCP path can't build seconds of queue.
    private let queued = Atomic<Int>(0)
    static let maxQueued = 384 * 1024
    private let lastInbound = Mutex(ContinuousClock.now)

    init(_ c: NWConnection) { connection = c }

    var description: String { "wss \(connection.endpoint)" }
    var kind: String { "wss" }
    var sourceHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return description
    }

    func send(_ packets: [[UInt8]]) {
        let ctx = NWConnection.ContentContext(identifier: "pkt", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
        connection.batch {
            for p in packets {
                guard queued.load(ordering: .relaxed) < Self.maxQueued else { return }
                queued.add(p.count, ordering: .relaxed)
                connection.send(content: Data(p), contentContext: ctx, isComplete: true, completion: .contentProcessed { [self] _ in
                    self.queued.subtract(p.count, ordering: .relaxed)
                })
            }
        }
    }

    func touched() { lastInbound.withLock { $0 = .now } }
    var idle: Duration { ContinuousClock.now - lastInbound.withLock { $0 } }
}

/// The Mac's listener on TCP 443 (or another port): TLS 1.3 with the Mac's self-signed identity, then a
/// WebSocket. Each binary message is one packet for `HostSessionServer` (`attach(datagrams)`).
public final class WSSServer: Sendable {
    private let queue = DispatchQueue(label: "clamshell.wss.server", qos: .userInteractive)
    nonisolated(unsafe) private var listener: NWListener?
    private let remotes = Mutex<[ObjectIdentifier: WSSRemote]>([:])
    public let datagrams: AsyncStream<UDPServer.Datagram>
    private let continuation: AsyncStream<UDPServer.Datagram>.Continuation
    nonisolated(unsafe) private var sweeper: DispatchSourceTimer?

    public init() {
        (datagrams, continuation) = AsyncStream.makeStream(of: UDPServer.Datagram.self, bufferingPolicy: .bufferingNewest(1024))
    }

    public var connectionCount: Int { remotes.withLock { $0.count } }

    /// Starts listening; returns the bound port.
    public func start(port: UInt16, identity: SecIdentity) async throws -> UInt16 {
        let tls = NWProtocolTLS.Options()
        guard let secIdentity = sec_identity_create(identity) else { throw TransportError.listenerFailed("bad TLS identity") }
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVideo
        params.allowLocalEndpointReuse = true
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 64 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        let l: NWListener
        do { l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any) } catch { throw TransportError.listenerFailed("\(error)") }
        let q = queue
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        listener = l
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.sweep() }
        t.resume()
        sweeper = t
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { k.resume(returning: l.port?.rawValue ?? port) }
                case .failed(let e): if once.claim() { k.resume(throwing: TransportError.listenerFailed("\(e)")) }
                case .cancelled: if once.claim() { k.resume(throwing: TransportError.closed) }
                default: break
                }
            }
            l.start(queue: q)
        }
    }

    public func stop() {
        listener?.cancel()
        sweeper?.cancel()
        for r in remotes.withLock({ Array($0.values) }) { r.connection.cancel() }
        remotes.withLock { $0.removeAll() }
        continuation.finish()
    }

    private func accept(_ c: NWConnection) {
        let r = WSSRemote(c)
        let id = ObjectIdentifier(r)
        remotes.withLock { $0[id] = r }
        c.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.remotes.withLock { _ = $0.removeValue(forKey: id) }
            default: break
            }
        }
        c.start(queue: queue)
        receive(r)
    }

    private func receive(_ r: WSSRemote) {
        r.connection.receiveMessage { [weak self] data, ctx, _, error in
            guard let self else { return }
            if let data, !data.isEmpty,
               (ctx?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode == .binary {
                r.touched()
                continuation.yield(UDPServer.Datagram(bytes: [UInt8](data), from: r))
            }
            if error != nil || r.connection.state == .cancelled { r.connection.cancel(); return }
            receive(r)
        }
    }

    /// Closes sockets that have been silent for 30 s (an idle scanner, or a phone that left).
    private func sweep() {
        for r in remotes.withLock({ Array($0.values) }) where r.idle > .seconds(30) { r.connection.cancel() }
    }
}

/// The phone's P3 path: `URLSessionWebSocketTask`, the one Apple API that follows the system HTTP proxy,
/// PAC and proxy authentication. It accepts any server certificate (ADR-0003): TLS here is camouflage.
public final class WSSClient: NSObject, PacketPath, URLSessionWebSocketDelegate, URLSessionDelegate, @unchecked Sendable {
    public let name: String
    public let datagrams: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation
    private let url: URL
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var opened: CheckedContinuation<Void, Error>?
    private var closed = false

    public init(host: String, port: UInt16, name: String = "wss") {
        self.name = name
        let h = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        url = URL(string: "wss://\(h):\(port)/") ?? URL(fileURLWithPath: "/")
        (datagrams, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(1024))
        super.init()
    }

    public func start() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4
        config.httpShouldUsePipelining = false
        config.networkServiceType = .responsiveData
        let s = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let t = s.webSocketTask(with: req)
        t.maximumMessageSize = 64 * 1024
        lock.withLock { session = s; task = t }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            lock.withLock { opened = k }
            t.resume()
        }
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.data(let d)):
                continuation.yield([UInt8](d))
                receive(t)
            case .success:
                receive(t)
            case .failure:
                finish()
            }
        }
    }

    public func send(_ packets: [[UInt8]]) {
        guard let t = lock.withLock({ closed ? nil : task }) else { return }
        for p in packets { t.send(.data(Data(p))) { _ in } }
    }

    public func stop() {
        let t = lock.withLock { () -> URLSessionWebSocketTask? in closed = true; return task }
        t?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        continuation.finish()
    }

    private func finish() {
        let k = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            closed = true
            defer { opened = nil }
            return opened
        }
        k?.resume(throwing: TransportError.closed)
        continuation.finish()
    }

    // MARK: URLSession delegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        let k = lock.withLock { () -> CheckedContinuation<Void, Error>? in defer { opened = nil }; return opened }
        k?.resume()
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) { finish() }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, !lock.withLock({ closed }) { let e = error as NSError
            print("# \(name) \(url.host ?? ""): \(e.localizedDescription) (\(e.code), stream \(e.userInfo["_kCFStreamErrorCodeKey"] ?? "-"), \((e.userInfo[NSUnderlyingErrorKey] as? NSError).map { "\($0.domain) \($0.code) \($0.userInfo["_kCFStreamErrorCodeKey"] ?? "")" } ?? ""))") }
        finish()
    }

    /// Any server certificate: the Noise handshake inside is what authenticates the Mac (ADR-0003).
    public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
