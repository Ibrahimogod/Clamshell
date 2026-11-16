import CryptoKit
import Foundation
import ClamshellWire

// Pairing (ADR-0014): once per phone, at home, on the LAN.
//
// The Mac opens a 120 s window and shows a QR code (`PairingInvite.string`) or a 16-character code
// (`PairingInvite.manualCode`). Both carry the same 80-bit one-time secret. The phone runs XXpsk3 with it,
// both sides show a 6-digit SAS, the person confirms the digits on the Mac, and the Mac then sends an
// encrypted "accepted" with its home endpoint. Both sides keep the peer's static key and a `psk_session`
// derived from the handshake; every later session is IKpsk2 with that PSK.
//
// Packets (outer type 0x05):
// ```
// 0x05 | step(1) | 00 00 | pairingId(4) | body
// step 1  phone → Mac  XX message 1 (payload: empty)
// step 2  Mac → phone  XX message 2 (payload: Mac name)
// step 3  phone → Mac  XX message 3 (payload: phone name)
// step 4  Mac → phone  ChaChaPoly(k_mac→phone, n=0, ad=header) of `PairingAccept`
// ```
// The phone repeats a step until it hears the next one; the Mac answers repeats from a cache.

public enum PairingError: Error, Equatable, Sendable {
    case malformed, wrongMac, closed, failed, rejected, deviceLimit
}

/// What the Mac shows: QR string or a manual code. The manual code carries only the secret; the phone then
/// learns the Mac's key from the handshake and its address from Bonjour or the address field.
public struct PairingInvite: Equatable, Sendable {
    public static let prefix = "CLAMPAIR1:"
    public static let secretLength = 10      // 80 bits = 16 base32 characters

    public var macPublicKey: [UInt8]?
    public var secret: [UInt8]
    public var macName: String
    public var port: UInt16
    public var addresses: [String]

    public init(macPublicKey: [UInt8]?, secret: [UInt8], macName: String = "", port: UInt16 = 0, addresses: [String] = []) {
        self.macPublicKey = macPublicKey
        self.secret = secret
        self.macName = macName
        self.port = port
        self.addresses = addresses
    }

    public static func newSecret() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<secretLength).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }

    /// The Noise PSK for the pairing handshake.
    public var psk: [UInt8] {
        Array(HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), info: Array("clamshell-pair-psk".utf8),
                                     outputByteCount: 32).withUnsafeBytes { Array($0) })
    }

    public var string: String {
        var w = ByteWriter(capacity: 96)
        w.u8(1)
        w.raw(macPublicKey ?? [UInt8](repeating: 0, count: 32))
        w.raw(secret)
        w.u16(port)
        w.lengthPrefixed(Array(macName.utf8.prefix(64)))
        let addrs = addresses.prefix(4)
        w.u8(UInt8(addrs.count))
        for a in addrs { w.lengthPrefixed(Array(a.utf8.prefix(64))) }
        return Self.prefix + Base64URL.encode(w.bytes)
    }

    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix(Self.prefix) {
            guard let bytes = Base64URL.decode(String(s.dropFirst(Self.prefix.count))) else { return nil }
            var r = ByteReader(bytes)
            do {
                guard try r.u8() == 1 else { return nil }
                let key = try r.bytes(32)
                let secret = try r.bytes(Self.secretLength)
                let port = try r.u16()
                let name = String(decoding: try r.lengthPrefixed(), as: UTF8.self)
                let n = Int(try r.u8())
                var addrs: [String] = []
                for _ in 0..<min(n, 4) { addrs.append(String(decoding: try r.lengthPrefixed(), as: UTF8.self)) }
                self.init(macPublicKey: key.contains(where: { $0 != 0 }) ? key : nil, secret: secret, macName: name, port: port, addresses: addrs)
            } catch { return nil }
        } else if let secret = Base32.decode(s), secret.count == Self.secretLength {
            self.init(macPublicKey: nil, secret: secret)
        } else {
            return nil
        }
    }

    /// `ABCD-EFGH-JKLM-NPQR`.
    public var manualCode: String {
        let c = Base32.encode(secret)
        return stride(from: 0, to: c.count, by: 4).map { i in
            let a = c.index(c.startIndex, offsetBy: i), b = c.index(a, offsetBy: min(4, c.count - i))
            return String(c[a..<b])
        }.joined(separator: "-")
    }
}

/// RFC 4648 base32 without padding; decoding ignores case, spaces and dashes and reads 0/1/8 as O/I/B.
public enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public static func encode(_ data: [UInt8]) -> String {
        var out = "", buffer = 0, bits = 0
        for b in data {
            buffer = buffer << 8 | Int(b); bits += 8
            while bits >= 5 { bits -= 5; out.append(alphabet[(buffer >> bits) & 31]) }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    public static func decode(_ s: String) -> [UInt8]? {
        var out: [UInt8] = [], buffer = 0, bits = 0
        for ch in s.uppercased() {
            if ch == "-" || ch == " " { continue }
            let c: Character = ch == "0" ? "O" : ch == "1" ? "I" : ch == "8" ? "B" : ch
            guard let v = alphabet.firstIndex(of: c) else { return nil }
            buffer = (buffer << 5 | v) & 0xFFFF; bits += 5
            if bits >= 8 { bits -= 8; out.append(UInt8((buffer >> bits) & 0xFF)) }
        }
        return out
    }
}

public enum Base64URL {
    public static func encode(_ b: [UInt8]) -> String {
        Data(b).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ s: String) -> [UInt8]? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64).map { [UInt8]($0) }
    }
}

/// Sent by the Mac when the person confirms (encrypted, step 4).
public struct PairingAccept: Equatable, Sendable {
    public var accepted: Bool
    public var udpPort: UInt16
    public var tcpPort: UInt16
    /// Where the phone finds the Mac away from home (router's public IP or a DNS name), if known.
    public var publicHost: String

    public init(accepted: Bool, udpPort: UInt16 = 0, tcpPort: UInt16 = 0, publicHost: String = "") {
        self.accepted = accepted
        self.udpPort = udpPort
        self.tcpPort = tcpPort
        self.publicHost = publicHost
    }

    var encoded: [UInt8] {
        var w = ByteWriter(capacity: 64)
        w.u8(accepted ? 1 : 0)
        w.u16(udpPort)
        w.u16(tcpPort)
        w.lengthPrefixed(Array(publicHost.utf8.prefix(253)))
        return w.bytes
    }

    init(_ b: [UInt8]) throws {
        var r = ByteReader(b)
        accepted = try r.u8() == 1
        udpPort = try r.u16()
        tcpPort = try r.u16()
        publicHost = String(decoding: try r.lengthPrefixed(), as: UTF8.self)
    }
}

/// What both sides derive from a finished handshake.
public struct PairingSecrets: Sendable, Equatable {
    public let sas: String
    public let pskSession: [UInt8]

    init(_ keys: TransportKeys) {
        let h = SymmetricKey(data: keys.handshakeHash)
        let sasBytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: h, info: Array("clamshell-sas".utf8), outputByteCount: 4)
            .withUnsafeBytes { Array($0) }
        let v = sasBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        sas = String(format: "%06u", v)
        // From the handshake hash: it binds both static keys, both ephemerals and the pairing secret.
        pskSession = HKDF<SHA256>.deriveKey(inputKeyMaterial: h, salt: Array("clamshell-psk-session".utf8),
                                            info: [], outputByteCount: 32).withUnsafeBytes { Array($0) }
    }
}

enum PairingPacket {
    static let headerLength = 8

    static func make(step: UInt8, id: UInt32, body: [UInt8]) -> [UInt8] {
        var w = ByteWriter(capacity: headerLength + body.count)
        w.u8(OuterPacketType.pairing.rawValue)
        w.u8(step)
        w.raw([0, 0])
        w.u32(id)
        w.raw(body)
        return w.bytes
    }

    static func parse(_ p: [UInt8]) -> (step: UInt8, id: UInt32, body: [UInt8])? {
        guard p.count >= headerLength, p[0] == OuterPacketType.pairing.rawValue else { return nil }
        var r = ByteReader(p)
        guard let _ = try? r.u8(), let step = try? r.u8(), let _ = try? r.bytes(2), let id = try? r.u32() else { return nil }
        return (step, id, r.rest())
    }

    static func seal(_ accept: PairingAccept, key: [UInt8], id: UInt32) throws -> [UInt8] {
        let header = Array(make(step: 4, id: id, body: []))
        let ct = try Noise.encrypt(key: SymmetricKey(data: key), n: 0, ad: header, plaintext: accept.encoded)
        return header + ct
    }

    static func open(_ packet: [UInt8], key: [UInt8]) throws -> PairingAccept {
        let header = Array(packet.prefix(headerLength))
        let pt = try Noise.decrypt(key: SymmetricKey(data: key), n: 0, ad: header, ciphertext: Array(packet.dropFirst(headerLength)))
        return try PairingAccept(pt)
    }
}

/// Mac side: one open pairing window. Pure state; the transport feeds it packets and sends its replies.
public struct PairingWindow: Sendable {
    public struct Request: Sendable, Equatable, Identifiable {
        public let id: UInt32
        public let phoneKey: [UInt8]
        public let phoneName: String
        public let sas: String
        let pskSession: [UInt8]
        let sendKey: [UInt8]
    }

    public enum Output: Sendable, Equatable {
        case none
        case reply([UInt8])
        /// A phone finished the handshake: show its SAS and ask the person.
        case request(Request)
        /// Too many failures, or the time ran out.
        case closed
    }

    private enum Slot: Sendable {
        case awaiting3(XXpsk3Responder, message2: [UInt8])
        case pending(Request)
        case done(reply: [UInt8])
    }

    public let invite: PairingInvite
    public let deadline: ContinuousClock.Instant
    public static let maxFailures = 3
    private let identity: StaticIdentity
    private var slots: [UInt32: Slot] = [:]
    public private(set) var failures = 0
    public private(set) var isClosed = false

    public init(identity: StaticIdentity, invite: PairingInvite, now: ContinuousClock.Instant, duration: Duration = .seconds(120)) {
        self.identity = identity
        self.invite = invite
        deadline = now + duration
    }

    public var pending: [Request] {
        slots.values.compactMap { if case .pending(let r) = $0 { r } else { nil } }.sorted { $0.id < $1.id }
    }

    public mutating func handle(_ packet: [UInt8], now: ContinuousClock.Instant) -> Output {
        if !isClosed && now >= deadline { isClosed = true; return .closed }
        guard !isClosed, let p = PairingPacket.parse(packet) else { return .none }
        switch (p.step, slots[p.id]) {
        case (1, nil):
            guard slots.count < 16,
                  var r = try? XXpsk3Responder(localStatic: identity.privateKey, psk: invite.psk, prologue: Self.prologue),
                  (try? r.readMessage1(p.body)) != nil,
                  let m2 = try? r.writeMessage2(payload: Array(invite.macName.utf8.prefix(64))) else { return fail() }
            let packet = PairingPacket.make(step: 2, id: p.id, body: m2)
            slots[p.id] = .awaiting3(r, message2: packet)
            return .reply(packet)
        case (1, .awaiting3(_, let m2)?):
            return .reply(m2)
        case (3, .awaiting3(var r, _)?):
            guard let read = try? r.readMessage3(p.body) else {
                slots[p.id] = nil
                return fail()
            }
            let s = PairingSecrets(read.keys)
            let request = Request(id: p.id, phoneKey: r.remoteStatic, phoneName: String(decoding: read.payload.prefix(64), as: UTF8.self),
                                  sas: s.sas, pskSession: s.pskSession, sendKey: read.keys.send)
            slots[p.id] = .pending(request)
            return .request(request)
        case (3, .done(let reply)?):
            return .reply(reply)
        default:
            return .none
        }
    }

    private mutating func fail() -> Output {
        failures += 1
        if failures >= Self.maxFailures { isClosed = true; return .closed }
        return .none
    }

    /// The person confirmed the digits. Returns the packet for the phone and the peer to store.
    public mutating func confirm(_ id: UInt32, accept: PairingAccept) throws -> (packet: [UInt8], peer: PeerConfig) {
        guard case .pending(let r)? = slots[id] else { throw PairingError.closed }
        let packet = try PairingPacket.seal(accept, key: r.sendKey, id: id)
        slots[id] = .done(reply: packet)
        return (packet, PeerConfig(publicKey: r.phoneKey, psk: r.pskSession, name: r.phoneName))
    }

    public mutating func reject(_ id: UInt32) -> [UInt8]? {
        guard case .pending(let r)? = slots[id] else { return nil }
        let packet = try? PairingPacket.seal(PairingAccept(accepted: false), key: r.sendKey, id: id)
        slots[id] = packet.map { .done(reply: $0) }
        return packet
    }

    public mutating func close() { isClosed = true }

    static let prologue = Array("clamshell.pair.v1".utf8)
}

/// Phone side of one pairing attempt. Pure state; the transport repeats `currentPacket` until `handle`
/// moves it on.
public struct PairingInitiator: Sendable {
    public enum Event: Sendable, Equatable {
        case none
        /// Message 3 is ready; show the SAS and keep sending `currentPacket` until the Mac answers.
        case showSAS(String)
        case accepted(mac: PeerConfig, endpoint: PairingAccept)
        case rejected
    }

    public let id: UInt32
    private var noise: XXpsk3Initiator
    private let invite: PairingInvite
    private let phoneName: String
    public private(set) var currentPacket: [UInt8]
    private var keys: TransportKeys?
    private var secrets: PairingSecrets?
    private var macName = ""
    public private(set) var finished = false

    public init(identity: StaticIdentity, invite: PairingInvite, phoneName: String, id: UInt32 = HandshakePacket.randomIndex()) throws {
        self.id = id
        self.invite = invite
        self.phoneName = phoneName
        noise = try XXpsk3Initiator(localStatic: identity.privateKey, psk: invite.psk, prologue: PairingWindow.prologue)
        currentPacket = PairingPacket.make(step: 1, id: id, body: try noise.writeMessage1(payload: []))
    }

    public mutating func handle(_ packet: [UInt8]) throws -> Event {
        guard !finished, let p = PairingPacket.parse(packet), p.id == id else { return .none }
        switch p.step {
        case 2 where keys == nil:
            let name: [UInt8]
            do { name = try noise.readMessage2(p.body) } catch { throw PairingError.failed }
            if let expected = invite.macPublicKey, expected != noise.remoteStatic { throw PairingError.wrongMac }
            macName = String(decoding: name.prefix(64), as: UTF8.self)
            let m3 = try noise.writeMessage3(payload: Array(phoneName.utf8.prefix(64)))
            keys = m3.keys
            let s = PairingSecrets(m3.keys)
            secrets = s
            currentPacket = PairingPacket.make(step: 3, id: id, body: m3.message)
            return .showSAS(s.sas)
        case 4:
            guard let keys, let secrets else { return .none }
            let accept: PairingAccept
            do { accept = try PairingPacket.open(packet, key: keys.receive) } catch { return .none }
            finished = true
            guard accept.accepted else { return .rejected }
            let name = macName.isEmpty ? invite.macName : macName
            return .accepted(mac: PeerConfig(publicKey: noise.remoteStatic, psk: secrets.pskSession, name: name), endpoint: accept)
        default:
            return .none
        }
    }
}
