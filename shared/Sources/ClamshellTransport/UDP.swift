import Foundation
import Network
import Synchronization

/// Bonjour service type for LAN discovery (path P1, ADR-0002).
public let clamshellBonjourType = "_clamshell._udp"

public enum TransportError: Error, Equatable, Sendable {
    case listenerFailed(String)
    case connectionFailed(String)
    case timedOut
    case closed
}

/// Where the Mac sends a peer's packets: a UDP address or a WebSocket connection (ADR-0002).
public protocol PacketRemote: AnyObject, Sendable {
    func send(_ packets: [[UInt8]])
    var description: String { get }
    /// "udp" or "wss", for the HUD and logs.
    var kind: String { get }
    /// Whether the peer's address is private, link-local or loopback. Pairing is accepted only from such
    /// addresses (ADR-0014), and never over the 443 edge.
    var isLocalNetwork: Bool { get }
    /// The source address without the port, for per-source limits.
    var sourceHost: String { get }
}

extension PacketRemote {
    public var isLocalNetwork: Bool { false }
    public var sourceHost: String { description }
}

/// RFC 1918 / 6598-free private, link-local, loopback and ULA addresses.
public func isLocalAddress(_ host: NWEndpoint.Host) -> Bool {
    switch host {
    case .ipv4(let a):
        let b = [UInt8](a.rawValue)
        guard b.count == 4 else { return false }
        return b[0] == 10 || b[0] == 127 || (b[0] == 172 && b[1] & 0xF0 == 16) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    case .ipv6(let a):
        let b = [UInt8](a.rawValue)
        guard b.count == 16 else { return false }
        if let v4 = a.asIPv4 { return isLocalAddress(.ipv4(v4)) }
        return a == .loopback || (b[0] == 0xFE && b[1] & 0xC0 == 0x80) || b[0] & 0xFE == 0xFC
    default:
        return false
    }
}

/// One way for the phone to reach the Mac (P1–P3). `datagrams` ends when the path dies.
public protocol PacketPath: AnyObject, Sendable {
    var name: String { get }
    var datagrams: AsyncStream<[UInt8]> { get }
    func start() async throws
    func send(_ packets: [[UInt8]])
    func stop()
}

/// A remote UDP peer as seen by the server. Network.framework gives one `NWConnection` per
/// remote address/port, so a roaming phone shows up as a new `UDPRemote`; sessions are routed
/// by receiver index, never by `UDPRemote` (ADR-0001).
public final class UDPRemote: Hashable, PacketRemote {
    // NWConnection is thread-safe for send/receive; all callbacks run on `queue`.
    let connection: NWConnection

    init(_ connection: NWConnection) { self.connection = connection }

    public static func == (a: UDPRemote, b: UDPRemote) -> Bool { a === b }
    public func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(self)) }
    public var description: String { "\(connection.endpoint)" }

    public var kind: String { "udp" }
    public var sourceHost: String {
        if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
        return description
    }

    public var isLocalNetwork: Bool {
        if case .hostPort(let host, _) = connection.endpoint { return isLocalAddress(host) }
        return false
    }

    /// Sends several datagrams in one batch (fewer syscalls on the hot path).
    public func send(_ datagrams: [[UInt8]]) {
        connection.batch {
            for d in datagrams { connection.send(content: Data(d), completion: .idempotent) }
        }
    }
}

/// Starts the receive loop for a connection, yielding each datagram.
private func receiveLoop(_ c: NWConnection, _ onDatagram: @escaping @Sendable ([UInt8]) -> Void, _ onEnd: @escaping @Sendable () -> Void) {
    c.receiveMessage { data, _, _, error in
        if let data, !data.isEmpty { onDatagram([UInt8](data)) }
        if error != nil || c.state == .cancelled {
            onEnd()
            return
        }
        receiveLoop(c, onDatagram, onEnd)
    }
}

private func udpParameters() -> NWParameters {
    let p = NWParameters.udp
    p.serviceClass = .interactiveVideo
    p.allowLocalEndpointReuse = true
    p.includePeerToPeer = false
    return p
}

/// UDP listener with optional Bonjour advertisement (Mac side).
public final class UDPServer: Sendable {
    public struct Datagram: Sendable {
        public let bytes: [UInt8]
        public let from: any PacketRemote
        public init(bytes: [UInt8], from: any PacketRemote) { self.bytes = bytes; self.from = from }
    }

    private let queue = DispatchQueue(label: "clamshell.udp.server", qos: .userInteractive)
    nonisolated(unsafe) private var listener: NWListener?
    public let datagrams: AsyncStream<Datagram>
    private let continuation: AsyncStream<Datagram>.Continuation

    public init() {
        (datagrams, continuation) = AsyncStream.makeStream(of: Datagram.self, bufferingPolicy: .bufferingNewest(512))
    }

    /// - Parameters:
    ///   - port: fixed port, or nil for any free port.
    ///   - bonjourName: advertise `_clamshell._udp` under this name (LAN only).
    /// - Returns: the bound port.
    public func start(port: UInt16?, bonjourName: String?) async throws -> UInt16 {
        let nwPort: NWEndpoint.Port = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        let l: NWListener
        do { l = try NWListener(using: udpParameters(), on: nwPort) } catch { throw TransportError.listenerFailed("\(error)") }
        if let bonjourName { l.service = NWListener.Service(name: bonjourName, type: clamshellBonjourType) }
        let cont = continuation
        let q = queue
        l.newConnectionHandler = { c in
            let remote = UDPRemote(c)
            c.start(queue: q)
            receiveLoop(c, { cont.yield(Datagram(bytes: $0, from: remote)) }, {})
        }
        listener = l
        return try await withCheckedThrowingContinuation { (k: CheckedContinuation<UInt16, Error>) in
            let once = OnceFlag()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { k.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e):
                    if once.claim() { k.resume(throwing: TransportError.listenerFailed("\(e)")) }
                case .cancelled:
                    if once.claim() { k.resume(throwing: TransportError.closed) }
                default:
                    break
                }
            }
            l.start(queue: q)
        }
    }

    public func send(_ datagrams: [[UInt8]], to remote: any PacketRemote) { remote.send(datagrams) }

    public func stop() {
        listener?.cancel()
        continuation.finish()
    }
}

/// UDP "connection" to one endpoint (phone side). Accepts a Bonjour service endpoint or host/port.
///
/// Roaming: a connected UDP socket stays on the interface it started on, so when the phone moves from
/// Wi-Fi to cellular (or to another Wi-Fi) the old socket goes quiet. On a better path, a path that stays
/// unviable for a second, or a failure after it was ready, this opens a new socket to the same address and
/// carries on. The Noise session is unaffected: the Mac follows the latest authentic source address
/// (`HostSessionServer`), so the stream continues without a new handshake.
public final class UDPClient: PacketPath {
    private struct State {
        var connection: NWConnection
        var resolved: NWEndpoint?
        var generation = 0
        var migrations = 0
        var viable = true
        var closed = false
    }

    private let queue = DispatchQueue(label: "clamshell.udp.client", qos: .userInteractive)
    private let state: Mutex<State>
    public let datagrams: AsyncStream<[UInt8]>
    private let continuation: AsyncStream<[UInt8]>.Continuation

    public init(endpoint: NWEndpoint, name: String = "udp") {
        self.name = name
        state = Mutex(State(connection: NWConnection(to: endpoint, using: udpParameters())))
        (datagrams, continuation) = AsyncStream.makeStream(of: [UInt8].self, bufferingPolicy: .bufferingNewest(512))
    }

    public convenience init(host: String, port: UInt16, name: String = "udp") {
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? .any), name: name)
    }

    public let name: String

    /// How often the socket moved to a new network path.
    public var migrations: Int { state.withLock { $0.migrations } }

    public func start() async throws {
        let c = state.withLock { $0.connection }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            c.stateUpdateHandler = { [weak self] st in
                switch st {
                case .ready:
                    if once.claim() {
                        self?.ready(c, generation: 0)
                        k.resume()
                    }
                case .failed(let e), .waiting(let e):
                    if once.claim() { k.resume(throwing: TransportError.connectionFailed("\(e)")) }
                    else { self?.lost(c, generation: 0) }
                case .cancelled:
                    if once.claim() { k.resume(throwing: TransportError.closed) }
                default:
                    break
                }
            }
            c.start(queue: queue)
        }
    }

    public func send(_ datagrams: [[UInt8]]) {
        let c = state.withLock { $0.connection }
        c.batch {
            for d in datagrams { c.send(content: Data(d), completion: .idempotent) }
        }
    }

    public func stop() {
        let c = state.withLock { s -> NWConnection in s.closed = true; return s.connection }
        c.cancel()
        continuation.finish()
    }

    // MARK: queue

    private func ready(_ c: NWConnection, generation: Int) {
        state.withLock { s in
            guard s.generation == generation else { return }
            s.viable = true
            // Keep the resolved address: a Bonjour name can't be resolved again once off the LAN.
            if s.resolved == nil, let remote = c.currentPath?.remoteEndpoint, case .hostPort = remote { s.resolved = remote }
        }
        receiveLoop(c, { [continuation] in continuation.yield($0) }, { [weak self] in self?.lost(c, generation: generation) })
        c.betterPathUpdateHandler = { [weak self] better in if better { self?.migrate(from: generation) } }
        c.viabilityUpdateHandler = { [weak self] viable in
            guard let self else { return }
            state.withLock { if $0.generation == generation { $0.viable = viable } }
            guard !viable else { return }
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, state.withLock({ $0.generation == generation && !$0.viable }) else { return }
                migrate(from: generation)
            }
        }
    }

    private func lost(_ c: NWConnection, generation: Int) {
        guard state.withLock({ !$0.closed && $0.generation == generation }) else { return }
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.migrate(from: generation) }
    }

    private func migrate(from generation: Int) {
        let swap = state.withLock { s -> (old: NWConnection, new: NWConnection, generation: Int)? in
            guard !s.closed, s.generation == generation else { return nil }
            let n = NWConnection(to: s.resolved ?? s.connection.endpoint, using: udpParameters())
            let old = s.connection
            s.connection = n
            s.generation += 1
            s.migrations += 1
            return (old, n, s.generation)
        }
        guard let swap else { return }
        swap.old.stateUpdateHandler = nil
        swap.old.betterPathUpdateHandler = nil
        swap.old.viabilityUpdateHandler = nil
        swap.old.cancel()
        let g = swap.generation, n = swap.new
        n.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.ready(n, generation: g)
            case .failed, .waiting: self?.lost(n, generation: g)
            default: break
            }
        }
        n.start(queue: queue)
    }
}

/// Resumes a continuation at most once from Network.framework's repeated state callbacks.
final class OnceFlag: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Browses for Clamshell Macs on the LAN.
public final class BonjourBrowser: Sendable {
    public struct Found: Sendable, Hashable {
        public let name: String
        public let endpoint: NWEndpoint
        public init(name: String, endpoint: NWEndpoint) {
            self.name = name
            self.endpoint = endpoint
        }
        public static func == (a: Found, b: Found) -> Bool { a.name == b.name }
        public func hash(into h: inout Hasher) { h.combine(name) }
    }

    private let queue = DispatchQueue(label: "clamshell.bonjour")
    private let browser: NWBrowser
    public let results: AsyncStream<[Found]>
    private let continuation: AsyncStream<[Found]>.Continuation

    public init() {
        browser = NWBrowser(for: .bonjour(type: clamshellBonjourType, domain: nil), using: .udp)
        (results, continuation) = AsyncStream.makeStream(of: [Found].self, bufferingPolicy: .bufferingNewest(1))
    }

    public func start() {
        let cont = continuation
        browser.browseResultsChangedHandler = { results, _ in
            let found = results.compactMap { r -> Found? in
                if case .service(let name, _, _, _) = r.endpoint { return Found(name: name, endpoint: r.endpoint) }
                return nil
            }
            cont.yield(found.sorted { $0.name < $1.name })
        }
        browser.start(queue: queue)
    }

    public func stop() {
        browser.cancel()
        continuation.finish()
    }
}
