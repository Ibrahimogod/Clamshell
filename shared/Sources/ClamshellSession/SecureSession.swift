import CryptoKit
import ClamshellWire

public enum SessionError: Error, Equatable, Sendable {
    case malformedPacket
    case wrongReceiver
    case replayed
    case decryptFailed
    case expired
    case counterExhausted
    case unknownPeer
    case staleTimestamp
    case badMac
    case handshakeFailed
}

/// Timer and limit constants, following WireGuard (whitepaper §6.1), with the 120 s rekey from ADR-0001.
public enum SessionLimits {
    public static let rekeyAfterTime: Duration = .seconds(120)
    public static let rejectAfterTime: Duration = .seconds(180)
    public static let rekeyAfterMessages: UInt64 = 1 << 60
    public static let rejectAfterMessages: UInt64 = UInt64.max - (1 << 13)
}

/// An established transport session: one key per direction, explicit counters, replay window.
///
/// Packet: `type(1)=0x04 | receiverIndex(4) | counter(8) | ChaChaPoly(payload)`; the 13-byte header
/// is the AEAD associated data, so it can't be altered either. The session is identified by
/// receiver index, never by address, which is what makes roaming work (ADR-0001).
public struct SecureSession: Sendable {
    public static let headerLength = 13
    public static let overhead = headerLength + Noise.tagLen

    public let localIndex: UInt32
    public let remoteIndex: UInt32
    public let peerStaticKey: [UInt8]
    public let isInitiator: Bool
    public let handshakeHash: [UInt8]
    public let createdAt: ContinuousClock.Instant

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    public private(set) var sendCounter: UInt64 = 0
    private var replay = ReplayWindow()
    /// The responder's session is unconfirmed until the first authentic packet from the initiator.
    /// With psk2 that packet also proves the initiator knows the pairing PSK. Don't stream before.
    public private(set) var isConfirmed: Bool

    init(keys: TransportKeys, localIndex: UInt32, remoteIndex: UInt32, peerStaticKey: [UInt8],
         isInitiator: Bool, now: ContinuousClock.Instant) {
        self.localIndex = localIndex
        self.remoteIndex = remoteIndex
        self.peerStaticKey = peerStaticKey
        self.isInitiator = isInitiator
        self.handshakeHash = keys.handshakeHash
        self.createdAt = now
        self.sendKey = SymmetricKey(data: keys.send)
        self.receiveKey = SymmetricKey(data: keys.receive)
        self.isConfirmed = isInitiator
    }

    public func age(now: ContinuousClock.Instant) -> Duration { now - createdAt }

    /// Initiator should start a new handshake (the old session keeps working meanwhile).
    public func needsRekey(now: ContinuousClock.Instant) -> Bool {
        age(now: now) >= SessionLimits.rekeyAfterTime || sendCounter >= SessionLimits.rekeyAfterMessages
    }

    public func isExpired(now: ContinuousClock.Instant) -> Bool { age(now: now) >= SessionLimits.rejectAfterTime }

    public mutating func seal(_ payload: [UInt8], now: ContinuousClock.Instant) throws -> [UInt8] {
        guard !isExpired(now: now) else { throw SessionError.expired }
        guard sendCounter < SessionLimits.rejectAfterMessages else { throw SessionError.counterExhausted }
        var w = ByteWriter(capacity: Self.overhead + payload.count)
        w.u8(OuterPacketType.transport.rawValue)
        w.u32(remoteIndex)
        w.u64(sendCounter)
        let header = w.bytes
        let ct: [UInt8]
        do {
            ct = try Noise.encrypt(key: sendKey, n: sendCounter, ad: header, plaintext: payload)
        } catch {
            throw SessionError.decryptFailed
        }
        sendCounter += 1
        w.raw(ct)
        return w.bytes
    }

    /// Reads just the receiver index of a transport packet, to route it to a session.
    public static func receiverIndex(of packet: [UInt8]) -> UInt32? {
        guard packet.count >= overhead, packet[0] == OuterPacketType.transport.rawValue else { return nil }
        return UInt32(packet[1]) << 24 | UInt32(packet[2]) << 16 | UInt32(packet[3]) << 8 | UInt32(packet[4])
    }

    public mutating func open(_ packet: [UInt8], now: ContinuousClock.Instant) throws -> [UInt8] {
        guard packet.count >= Self.overhead else { throw SessionError.malformedPacket }
        var r = ByteReader(packet)
        guard try r.u8() == OuterPacketType.transport.rawValue else { throw SessionError.malformedPacket }
        guard try r.u32() == localIndex else { throw SessionError.wrongReceiver }
        let counter = try r.u64()
        guard !isExpired(now: now) else { throw SessionError.expired }
        guard counter < SessionLimits.rejectAfterMessages else { throw SessionError.counterExhausted }
        guard replay.canAccept(counter) else { throw SessionError.replayed }
        let header = Array(packet[0..<Self.headerLength])
        let pt: [UInt8]
        do {
            pt = try Noise.decrypt(key: receiveKey, n: counter, ad: header, ciphertext: Array(packet[Self.headerLength...]))
        } catch {
            throw SessionError.decryptFailed
        }
        guard replay.mark(counter) else { throw SessionError.replayed }
        isConfirmed = true
        return pt
    }
}
