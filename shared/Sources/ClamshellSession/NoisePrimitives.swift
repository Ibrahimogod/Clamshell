import CryptoKit
import Foundation

/// Errors from the Noise layer. Messages are deliberately generic: they're logged locally, never
/// sent to the peer, and must not help an attacker distinguish failure causes.
public enum NoiseError: Error, Equatable, Sendable {
    case invalidKey
    case decryptFailed
    case nonceExhausted
    case malformedMessage
    case dhFailed
}

/// The Noise primitives for `25519_ChaChaPoly_SHA256`, all from CryptoKit (ADR-0001).
enum Noise {
    static let hashLen = 32
    static let dhLen = 32
    static let tagLen = 16

    static func hash(_ parts: [UInt8]...) -> [UInt8] {
        var h = SHA256()
        for p in parts { h.update(data: p) }
        return Array(h.finalize())
    }

    static func hmac(key: [UInt8], _ parts: [UInt8]...) -> [UInt8] {
        var m = HMAC<SHA256>(key: SymmetricKey(data: key))
        for p in parts { m.update(data: p) }
        return Array(m.finalize())
    }

    /// Noise spec §4.3 HKDF with 2 or 3 outputs.
    static func hkdf2(chainingKey: [UInt8], ikm: [UInt8]) -> ([UInt8], [UInt8]) {
        let temp = hmac(key: chainingKey, ikm)
        let o1 = hmac(key: temp, [0x01])
        let o2 = hmac(key: temp, o1, [0x02])
        return (o1, o2)
    }

    static func hkdf3(chainingKey: [UInt8], ikm: [UInt8]) -> ([UInt8], [UInt8], [UInt8]) {
        let temp = hmac(key: chainingKey, ikm)
        let o1 = hmac(key: temp, [0x01])
        let o2 = hmac(key: temp, o1, [0x02])
        let o3 = hmac(key: temp, o2, [0x03])
        return (o1, o2, o3)
    }

    static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pubRaw: [UInt8]) throws -> [UInt8] {
        guard pubRaw.count == dhLen else { throw NoiseError.invalidKey }
        do {
            let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pubRaw)
            let secret = try priv.sharedSecretFromKeyAgreement(with: pub)
            let bytes = secret.withUnsafeBytes { Array($0) }
            // Reject the all-zero output from low-order points.
            guard bytes.contains(where: { $0 != 0 }) else { throw NoiseError.dhFailed }
            return bytes
        } catch let e as NoiseError {
            throw e
        } catch {
            throw NoiseError.dhFailed
        }
    }

    /// ChaChaPoly nonce: 32 zero bits followed by the 64-bit counter, little-endian (Noise §12.3).
    static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        var v = n
        for i in 0..<8 {
            bytes[4 + i] = UInt8(truncatingIfNeeded: v)
            v >>= 8
        }
        do { return try ChaChaPoly.Nonce(data: bytes) } catch { throw NoiseError.malformedMessage }
    }

    static func encrypt(key: SymmetricKey, n: UInt64, ad: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        do {
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: try nonce(n), authenticating: ad)
            return Array(box.ciphertext) + Array(box.tag)
        } catch let e as NoiseError {
            throw e
        } catch {
            throw NoiseError.decryptFailed
        }
    }

    static func decrypt(key: SymmetricKey, n: UInt64, ad: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
        guard ciphertext.count >= tagLen else { throw NoiseError.decryptFailed }
        let split = ciphertext.count - tagLen
        do {
            let box = try ChaChaPoly.SealedBox(nonce: try nonce(n),
                                               ciphertext: ciphertext[..<split],
                                               tag: ciphertext[split...])
            return Array(try ChaChaPoly.open(box, using: key, authenticating: ad))
        } catch {
            throw NoiseError.decryptFailed
        }
    }
}

/// Noise CipherState (§5.1).
struct CipherState: Sendable {
    private(set) var key: SymmetricKey?
    private(set) var n: UInt64 = 0

    init(key: [UInt8]?) {
        self.key = key.map { SymmetricKey(data: $0) }
    }

    var hasKey: Bool { key != nil }

    mutating func encrypt(ad: [UInt8], plaintext: [UInt8]) throws -> [UInt8] {
        guard let key else { return plaintext }
        guard n < UInt64.max else { throw NoiseError.nonceExhausted }
        let ct = try Noise.encrypt(key: key, n: n, ad: ad, plaintext: plaintext)
        n += 1
        return ct
    }

    mutating func decrypt(ad: [UInt8], ciphertext: [UInt8]) throws -> [UInt8] {
        guard let key else { return ciphertext }
        guard n < UInt64.max else { throw NoiseError.nonceExhausted }
        let pt = try Noise.decrypt(key: key, n: n, ad: ad, ciphertext: ciphertext)
        n += 1
        return pt
    }
}

/// Noise SymmetricState (§5.2).
struct SymmetricState: Sendable {
    private(set) var ck: [UInt8]
    private(set) var h: [UInt8]
    private var cipher = CipherState(key: nil)

    init(protocolName: String) {
        let name = Array(protocolName.utf8)
        if name.count <= Noise.hashLen {
            h = name + [UInt8](repeating: 0, count: Noise.hashLen - name.count)
        } else {
            h = Noise.hash(name)
        }
        ck = h
    }

    mutating func mixHash(_ data: [UInt8]) { h = Noise.hash(h, data) }

    mutating func mixKey(_ ikm: [UInt8]) {
        let (newCk, tempK) = Noise.hkdf2(chainingKey: ck, ikm: ikm)
        ck = newCk
        cipher = CipherState(key: tempK)
    }

    mutating func mixKeyAndHash(_ ikm: [UInt8]) {
        let (newCk, tempH, tempK) = Noise.hkdf3(chainingKey: ck, ikm: ikm)
        ck = newCk
        mixHash(tempH)
        cipher = CipherState(key: tempK)
    }

    mutating func encryptAndHash(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ct = try cipher.encrypt(ad: h, plaintext: plaintext)
        mixHash(ct)
        return ct
    }

    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws -> [UInt8] {
        let pt = try cipher.decrypt(ad: h, ciphertext: ciphertext)
        mixHash(ciphertext)
        return pt
    }

    /// Returns (initiator→responder key, responder→initiator key).
    func split() -> ([UInt8], [UInt8]) { Noise.hkdf2(chainingKey: ck, ikm: []) }
}
