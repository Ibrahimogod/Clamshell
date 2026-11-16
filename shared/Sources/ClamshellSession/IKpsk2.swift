import CryptoKit

/// Pure Noise `IKpsk2_25519_ChaChaPoly_SHA256`, checked against the Cacophony test vector.
///
/// ```
/// IKpsk2:
///   <- s
///   ...
///   -> e, es, s, ss
///   <- e, ee, se, psk
/// ```
/// In PSK handshakes every `e` token is followed by `MixKey(e.public)` (Noise §9.2).
public enum IKpsk2 {
    public static let protocolName = "Noise_IKpsk2_25519_ChaChaPoly_SHA256"
    public static let pskLen = 32
    /// msg1 = e(32) + enc(s)(32+16) + enc(payload)(n+16)
    public static func message1Length(payload: Int) -> Int { 32 + 48 + payload + 16 }
    /// msg2 = e(32) + enc(payload)(n+16)
    public static func message2Length(payload: Int) -> Int { 32 + payload + 16 }
}

/// Raw symmetric keys produced by `Split()`. Converted into a `SecureSession` by the packet layer.
public struct TransportKeys: Sendable {
    public let send: [UInt8]
    public let receive: [UInt8]
    public let handshakeHash: [UInt8]
}

public struct IKpsk2Initiator: Sendable {
    private var ss: SymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private let rs: [UInt8]
    private let psk: [UInt8]
    private var wroteMessage1 = false

    /// - Parameter ephemeral: inject only in tests (test vectors). Production code passes nil.
    public init(localStatic: Curve25519.KeyAgreement.PrivateKey, remoteStatic: [UInt8], psk: [UInt8],
                prologue: [UInt8], ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws {
        guard remoteStatic.count == 32, psk.count == IKpsk2.pskLen else { throw NoiseError.invalidKey }
        ss = SymmetricState(protocolName: IKpsk2.protocolName)
        ss.mixHash(prologue)
        ss.mixHash(remoteStatic)            // pre-message: <- s
        s = localStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        rs = remoteStatic
        self.psk = psk
    }

    public mutating func writeMessage1(payload: [UInt8]) throws -> [UInt8] {
        guard !wroteMessage1 else { throw NoiseError.malformedMessage }
        wroteMessage1 = true
        var out: [UInt8] = []
        let ePub = Array(e.publicKey.rawRepresentation)
        out += ePub                                    // e
        ss.mixHash(ePub)
        ss.mixKey(ePub)                                // psk mode
        ss.mixKey(try Noise.dh(e, rs))                 // es
        out += try ss.encryptAndHash(Array(s.publicKey.rawRepresentation)) // s
        ss.mixKey(try Noise.dh(s, rs))                 // ss
        out += try ss.encryptAndHash(payload)
        return out
    }

    public mutating func readMessage2(_ msg: [UInt8]) throws -> (payload: [UInt8], keys: TransportKeys) {
        guard wroteMessage1, msg.count >= IKpsk2.message2Length(payload: 0) else { throw NoiseError.malformedMessage }
        let re = Array(msg[0..<32])
        ss.mixHash(re)                                 // e
        ss.mixKey(re)                                  // psk mode
        ss.mixKey(try Noise.dh(e, re))                 // ee
        ss.mixKey(try Noise.dh(s, re))                 // se (initiator: DH(s, re))
        ss.mixKeyAndHash(psk)                          // psk
        let payload = try ss.decryptAndHash(Array(msg[32...]))
        let (k1, k2) = ss.split()
        return (payload, TransportKeys(send: k1, receive: k2, handshakeHash: ss.h))
    }
}

public struct IKpsk2Responder: Sendable {
    private var ss: SymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private var re: [UInt8] = []
    private var rs: [UInt8] = []
    private var readMessage1Done = false

    public init(localStatic: Curve25519.KeyAgreement.PrivateKey, prologue: [UInt8],
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
        ss = SymmetricState(protocolName: IKpsk2.protocolName)
        ss.mixHash(prologue)
        ss.mixHash(Array(localStatic.publicKey.rawRepresentation))  // pre-message: <- s
        s = localStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
    }

    /// Returns the initiator's static public key (look it up in the allow-list before replying)
    /// and the decrypted payload.
    public mutating func readMessage1(_ msg: [UInt8]) throws -> (initiatorStatic: [UInt8], payload: [UInt8]) {
        guard !readMessage1Done, msg.count >= IKpsk2.message1Length(payload: 0) else { throw NoiseError.malformedMessage }
        readMessage1Done = true
        re = Array(msg[0..<32])
        ss.mixHash(re)                                 // e
        ss.mixKey(re)                                  // psk mode
        ss.mixKey(try Noise.dh(s, re))                 // es (responder: DH(s, re))
        rs = try ss.decryptAndHash(Array(msg[32..<80])) // s
        guard rs.count == 32 else { throw NoiseError.malformedMessage }
        ss.mixKey(try Noise.dh(s, rs))                 // ss
        let payload = try ss.decryptAndHash(Array(msg[80...]))
        return (rs, payload)
    }

    public mutating func writeMessage2(payload: [UInt8], psk: [UInt8]) throws -> (message: [UInt8], keys: TransportKeys) {
        guard readMessage1Done, psk.count == IKpsk2.pskLen else { throw NoiseError.malformedMessage }
        var out: [UInt8] = []
        let ePub = Array(e.publicKey.rawRepresentation)
        out += ePub                                    // e
        ss.mixHash(ePub)
        ss.mixKey(ePub)                                // psk mode
        ss.mixKey(try Noise.dh(e, re))                 // ee
        ss.mixKey(try Noise.dh(e, rs))                 // se (responder: DH(e, rs))
        ss.mixKeyAndHash(psk)                          // psk
        out += try ss.encryptAndHash(payload)
        let (k1, k2) = ss.split()
        return (out, TransportKeys(send: k2, receive: k1, handshakeHash: ss.h))
    }
}
