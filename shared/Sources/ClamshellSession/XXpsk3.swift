import CryptoKit

/// `Noise_XXpsk3_25519_ChaChaPoly_SHA256`, used once per device for pairing (ADR-0014).
/// ```
/// -> e
/// <- e, ee, s, es
/// -> s, se, psk
/// ```
/// The phone is the initiator. Neither side needs the other's static key in advance; both prove theirs,
/// and the one-time pairing secret (`psk`) is mixed in last, so a party without it can't finish message 3.
public enum XXpsk3 {
    public static let protocolName = "Noise_XXpsk3_25519_ChaChaPoly_SHA256"
    public static func message1Length(payload: Int) -> Int { 32 + payload + 16 }
    public static func message2Length(payload: Int) -> Int { 32 + 48 + payload + 16 }
    public static func message3Length(payload: Int) -> Int { 48 + payload + 16 }
}

public struct XXpsk3Initiator: Sendable {
    private var ss: SymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private let psk: [UInt8]
    private var re: [UInt8] = []
    public private(set) var remoteStatic: [UInt8] = []
    private var step = 0

    public init(localStatic: Curve25519.KeyAgreement.PrivateKey, psk: [UInt8], prologue: [UInt8],
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws {
        guard psk.count == 32 else { throw NoiseError.invalidKey }
        ss = SymmetricState(protocolName: XXpsk3.protocolName)
        ss.mixHash(prologue)
        s = localStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        self.psk = psk
    }

    public mutating func writeMessage1(payload: [UInt8]) throws -> [UInt8] {
        guard step == 0 else { throw NoiseError.malformedMessage }
        step = 1
        let ePub = Array(e.publicKey.rawRepresentation)
        ss.mixHash(ePub)
        ss.mixKey(ePub)                                // psk mode
        return ePub + (try ss.encryptAndHash(payload))
    }

    public mutating func readMessage2(_ msg: [UInt8]) throws -> [UInt8] {
        guard step == 1, msg.count >= XXpsk3.message2Length(payload: 0) else { throw NoiseError.malformedMessage }
        step = 2
        re = Array(msg[0..<32])
        ss.mixHash(re)
        ss.mixKey(re)                                  // psk mode
        ss.mixKey(try Noise.dh(e, re))                 // ee
        remoteStatic = try ss.decryptAndHash(Array(msg[32..<80]))   // s
        ss.mixKey(try Noise.dh(e, remoteStatic))       // es (initiator: DH(e, rs))
        return try ss.decryptAndHash(Array(msg[80...]))
    }

    public mutating func writeMessage3(payload: [UInt8]) throws -> (message: [UInt8], keys: TransportKeys) {
        guard step == 2 else { throw NoiseError.malformedMessage }
        step = 3
        var out = try ss.encryptAndHash(Array(s.publicKey.rawRepresentation))  // s
        ss.mixKey(try Noise.dh(s, re))                 // se (initiator: DH(s, re))
        ss.mixKeyAndHash(psk)                          // psk
        out += try ss.encryptAndHash(payload)
        let (k1, k2) = ss.split()
        return (out, TransportKeys(send: k1, receive: k2, handshakeHash: ss.h))
    }
}

public struct XXpsk3Responder: Sendable {
    private var ss: SymmetricState
    private let s: Curve25519.KeyAgreement.PrivateKey
    private let e: Curve25519.KeyAgreement.PrivateKey
    private let psk: [UInt8]
    private var re: [UInt8] = []
    public private(set) var remoteStatic: [UInt8] = []
    private var step = 0

    public init(localStatic: Curve25519.KeyAgreement.PrivateKey, psk: [UInt8], prologue: [UInt8],
                ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) throws {
        guard psk.count == 32 else { throw NoiseError.invalidKey }
        ss = SymmetricState(protocolName: XXpsk3.protocolName)
        ss.mixHash(prologue)
        s = localStatic
        e = ephemeral ?? Curve25519.KeyAgreement.PrivateKey()
        self.psk = psk
    }

    public mutating func readMessage1(_ msg: [UInt8]) throws -> [UInt8] {
        guard step == 0, msg.count >= XXpsk3.message1Length(payload: 0) else { throw NoiseError.malformedMessage }
        step = 1
        re = Array(msg[0..<32])
        ss.mixHash(re)
        ss.mixKey(re)                                  // psk mode
        return try ss.decryptAndHash(Array(msg[32...]))
    }

    public mutating func writeMessage2(payload: [UInt8]) throws -> [UInt8] {
        guard step == 1 else { throw NoiseError.malformedMessage }
        step = 2
        let ePub = Array(e.publicKey.rawRepresentation)
        ss.mixHash(ePub)
        ss.mixKey(ePub)                                // psk mode
        ss.mixKey(try Noise.dh(e, re))                 // ee
        var out = ePub
        out += try ss.encryptAndHash(Array(s.publicKey.rawRepresentation))  // s
        ss.mixKey(try Noise.dh(s, re))                 // es (responder: DH(s, re))
        out += try ss.encryptAndHash(payload)
        return out
    }

    public mutating func readMessage3(_ msg: [UInt8]) throws -> (payload: [UInt8], keys: TransportKeys) {
        guard step == 2, msg.count >= XXpsk3.message3Length(payload: 0) else { throw NoiseError.malformedMessage }
        step = 3
        remoteStatic = try ss.decryptAndHash(Array(msg[0..<48]))    // s
        ss.mixKey(try Noise.dh(e, remoteStatic))       // se (responder: DH(e, rs))
        ss.mixKeyAndHash(psk)                          // psk
        let payload = try ss.decryptAndHash(Array(msg[48...]))
        let (k1, k2) = ss.split()
        return (payload, TransportKeys(send: k2, receive: k1, handshakeHash: ss.h))
    }
}
