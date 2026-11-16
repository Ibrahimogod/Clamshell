import CryptoKit
import ClamshellWire

/// A device's long-term X25519 key. In M1 it's stored in the Keychain as raw bytes; in M3 it's
/// wrapped by a Secure Enclave key and unlocked with Touch ID (ADR-0014).
public struct StaticIdentity: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() { privateKey = Curve25519.KeyAgreement.PrivateKey() }

    public init(rawPrivateKey: [UInt8]) throws {
        do { privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: rawPrivateKey) } catch { throw NoiseError.invalidKey }
    }

    public var publicKey: [UInt8] { Array(privateKey.publicKey.rawRepresentation) }
    /// Secret. Only for writing to the Keychain.
    public var rawPrivateKey: [UInt8] { Array(privateKey.rawRepresentation) }
}

/// What one side knows about the other after pairing.
public struct PeerConfig: Sendable, Hashable {
    public var publicKey: [UInt8]
    public var psk: [UInt8]
    public var name: String

    public init(publicKey: [UInt8], psk: [UInt8], name: String) {
        self.publicKey = publicKey
        self.psk = psk
        self.name = name
    }
}

/// Packet layouts for the two handshake messages:
/// ```
/// initiation: 0x01 | 000000 | senderIndex(4) | noise msg1 | mac1(16)
/// response:   0x02 | 000000 | senderIndex(4) | receiverIndex(4) | noise msg2 | mac1(16)
/// ```
/// `mac1 = HMAC-SHA256(SHA256("mac1----" ‖ receiverStaticPublic), packet-before-mac1)[0..<16]`.
/// It lets the Mac drop packets from anyone who doesn't know its public key before doing any DH,
/// so scanners get silence (docs/security.md T3).
public enum HandshakePacket {
    public static let prologue = Array("clamshell.noise".utf8)
    public static let macLength = 16
    static let initiationHeader = 8
    static let responseHeader = 12

    static func mac1(receiverStatic: [UInt8], _ body: ArraySlice<UInt8>) -> [UInt8] {
        let key = Noise.hash(Array("mac1----".utf8), receiverStatic)
        return Array(Noise.hmac(key: key, Array(body)).prefix(macLength))
    }

    static func verifyMac1(receiverStatic: [UInt8], packet: [UInt8]) -> Bool {
        guard packet.count > macLength else { return false }
        let split = packet.count - macLength
        let expected = mac1(receiverStatic: receiverStatic, packet[..<split])
        // Constant-time compare.
        var diff: UInt8 = 0
        for (a, b) in zip(expected, packet[split...]) { diff |= a ^ b }
        return diff == 0
    }

    public static func randomIndex() -> UInt32 {
        var g = SystemRandomNumberGenerator()
        return UInt32.random(in: 1...UInt32.max, using: &g)
    }
}

/// Phone side (initiator).
public struct ClientHandshake: Sendable {
    public let localIndex: UInt32
    public let initiationPacket: [UInt8]
    private var noise: IKpsk2Initiator
    private let identity: StaticIdentity
    private let server: PeerConfig

    public init(identity: StaticIdentity, server: PeerConfig, payload: [InnerMessage],
                timestamp: TAI64N = .now(), localIndex: UInt32 = HandshakePacket.randomIndex(),
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws {
        self.identity = identity
        self.server = server
        self.localIndex = localIndex
        noise = try IKpsk2Initiator(localStatic: identity.privateKey, remoteStatic: server.publicKey, psk: server.psk,
                                    prologue: HandshakePacket.prologue, ephemeral: ephemeral)
        var w = ByteWriter(capacity: 256)
        w.u8(OuterPacketType.handshakeInitiation.rawValue)
        w.raw([0, 0, 0])
        w.u32(localIndex)
        w.raw(try noise.writeMessage1(payload: timestamp.bytes + InnerMessage.encodeAll(payload)))
        let body = w.bytes
        initiationPacket = body + HandshakePacket.mac1(receiverStatic: server.publicKey, body[...])
    }

    public mutating func complete(response packet: [UInt8], now: ContinuousClock.Instant) throws -> (session: SecureSession, messages: [InnerMessage]) {
        let minLength = HandshakePacket.responseHeader + IKpsk2.message2Length(payload: 0) + HandshakePacket.macLength
        guard packet.count >= minLength, packet[0] == OuterPacketType.handshakeResponse.rawValue else { throw SessionError.malformedPacket }
        guard HandshakePacket.verifyMac1(receiverStatic: identity.publicKey, packet: packet) else { throw SessionError.badMac }
        var r = ByteReader(packet)
        _ = try r.bytes(4)
        let remoteIndex = try r.u32()
        guard try r.u32() == localIndex else { throw SessionError.wrongReceiver }
        let msg2 = Array(packet[HandshakePacket.responseHeader..<(packet.count - HandshakePacket.macLength)])
        let result: (payload: [UInt8], keys: TransportKeys)
        do { result = try noise.readMessage2(msg2) } catch { throw SessionError.handshakeFailed }
        let messages = try InnerMessage.decodeAll(result.payload)
        let session = SecureSession(keys: result.keys, localIndex: localIndex, remoteIndex: remoteIndex,
                                    peerStaticKey: server.publicKey, isInitiator: true, now: now)
        return (session, messages)
    }
}

/// Mac side (responder): allow-list, replay protection on msg1, response construction.
public struct HostResponder: Sendable {
    public let identity: StaticIdentity
    public private(set) var peers: [[UInt8]: PeerConfig]
    /// Greatest TAI64N seen per initiator key. A msg1 with an equal or older stamp is a replay.
    private var lastTimestamp: [[UInt8]: TAI64N] = [:]
    /// Tests only: accept an unknown initiator key if it completes the handshake with this PSK. Ignored in
    /// Release builds (the apps never set it; pairing is ADR-0014), so it can't become an open door.
    public var developmentPSK: [UInt8]?

    public init(identity: StaticIdentity, peers: [PeerConfig] = [], developmentPSK: [UInt8]? = nil) {
        self.identity = identity
        self.peers = Dictionary(peers.map { ($0.publicKey, $0) }, uniquingKeysWith: { _, b in b })
        self.developmentPSK = developmentPSK
    }

    public mutating func addPeer(_ peer: PeerConfig) { peers[peer.publicKey] = peer }

    /// Revocation takes effect for the next handshake; callers also drop live sessions for the key.
    public mutating func removePeer(publicKey: [UInt8]) {
        peers[publicKey] = nil
        lastTimestamp[publicKey] = nil
    }

    public struct Accepted: Sendable {
        public let responsePacket: [UInt8]
        public let session: SecureSession
        public let peerMessages: [InnerMessage]
        public let isKnownPeer: Bool
    }

    /// - Parameter reply: builds the Mac's msg2 payload from the phone's msg1 messages (Hello negotiation).
    public mutating func handleInitiation(_ packet: [UInt8], now: ContinuousClock.Instant,
                                          localIndex: UInt32 = HandshakePacket.randomIndex(),
                                          ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil,
                                          reply: ([InnerMessage]) -> [InnerMessage]) throws -> Accepted {
        let minLength = HandshakePacket.initiationHeader + IKpsk2.message1Length(payload: 12) + HandshakePacket.macLength
        guard packet.count >= minLength, packet[0] == OuterPacketType.handshakeInitiation.rawValue else { throw SessionError.malformedPacket }
        guard HandshakePacket.verifyMac1(receiverStatic: identity.publicKey, packet: packet) else { throw SessionError.badMac }
        var r = ByteReader(packet)
        _ = try r.bytes(4)
        let remoteIndex = try r.u32()
        let msg1 = Array(packet[HandshakePacket.initiationHeader..<(packet.count - HandshakePacket.macLength)])

        var noise = IKpsk2Responder(localStatic: identity.privateKey, prologue: HandshakePacket.prologue, ephemeral: ephemeral)
        let read: (initiatorStatic: [UInt8], payload: [UInt8])
        do { read = try noise.readMessage1(msg1) } catch { throw SessionError.handshakeFailed }
        guard read.payload.count >= 12 else { throw SessionError.malformedPacket }

        let known = peers[read.initiatorStatic]
        #if DEBUG
        let fallback = developmentPSK
        #else
        let fallback: [UInt8]? = nil
        #endif
        guard let psk = known?.psk ?? fallback else { throw SessionError.unknownPeer }

        let stamp = try TAI64N(bytes: Array(read.payload[0..<12]))
        if let last = lastTimestamp[read.initiatorStatic], stamp <= last { throw SessionError.staleTimestamp }
        lastTimestamp[read.initiatorStatic] = stamp

        let messages = try InnerMessage.decodeAll(Array(read.payload[12...]))
        let written: (message: [UInt8], keys: TransportKeys)
        do { written = try noise.writeMessage2(payload: InnerMessage.encodeAll(reply(messages)), psk: psk) } catch { throw SessionError.handshakeFailed }

        var w = ByteWriter(capacity: 128 + written.message.count)
        w.u8(OuterPacketType.handshakeResponse.rawValue)
        w.raw([0, 0, 0])
        w.u32(localIndex)
        w.u32(remoteIndex)
        w.raw(written.message)
        let body = w.bytes
        let response = body + HandshakePacket.mac1(receiverStatic: read.initiatorStatic, body[...])
        let session = SecureSession(keys: written.keys, localIndex: localIndex, remoteIndex: remoteIndex,
                                    peerStaticKey: read.initiatorStatic, isInitiator: false, now: now)
        return Accepted(responsePacket: response, session: session, peerMessages: messages, isKnownPeer: known != nil)
    }
}
