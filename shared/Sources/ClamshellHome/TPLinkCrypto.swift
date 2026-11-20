import CommonCrypto
import CryptoKit
import Foundation

/// The encryption the TP-Link Archer VR/MR web UI puts around every request once "GDPR encryption" is on
/// (the VR400 has it). Worked out from the router's own `tpEncrypt.js`, not copied from anyone's code:
///
/// - The browser makes up a 16-character AES-128 key and IV (plain ASCII digits, used as their bytes).
/// - Bodies are AES-CBC with PKCS#7 padding, sent as base64.
/// - Each body carries a signature: the router's 512-bit RSA key (no padding, 64-byte chunks) over
///   `key=…&iv=…&h=<md5("admin"+password)>&s=<seq + body length>` at login, then `h=…&s=…` afterwards.
///   `seq` comes from `/cgi/getParm`. Signing with the AES key is how the router learns it.
struct TPLinkEncryptor: Sendable {
    let key: String
    let iv: String
    /// Lower-case hex MD5 of `"admin" + password`.
    let hash: String
    let rsa: RawRSA

    init(key: String, iv: String, password: String, rsa: RawRSA) {
        self.key = key
        self.iv = iv
        self.rsa = rsa
        hash = Self.md5Hex("admin" + password)
    }

    /// A fresh key and IV, like the web UI's (it uses the clock and `Math.random`; we use the system RNG).
    static func randomDigits(_ count: Int) -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<count).map { _ in Character(String(Int.random(in: 0...9, using: &rng))) })
    }

    /// `(data, sign)` for one request. `login` adds the AES key and IV to what's signed.
    func seal(_ plaintext: String, seq: Int, login: Bool) -> (data: String, sign: String)? {
        guard let data = Self.aes(Array(plaintext.utf8), key: key, iv: iv, encrypt: true)?.base64 else { return nil }
        let s = seq + data.utf8.count
        let signed = (login ? "key=\(key)&iv=\(iv)&" : "") + "h=\(hash)&s=\(s)"
        guard let sign = sign(signed) else { return nil }
        return (data, sign)
    }

    /// Decrypts a base64 AES body from the router, or nil if it isn't one.
    func open(_ base64: String) -> String? {
        let trimmed = base64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bytes = Data(base64Encoded: trimmed), !bytes.isEmpty,
              let plain = Self.aes(Array(bytes), key: key, iv: iv, encrypt: false) else { return nil }
        return String(bytes: plain, encoding: .utf8)
    }

    /// The web UI's `$.rsa.encrypt(text, nn, ee, 512, 0)`: 64-character chunks, each zero-padded on the
    /// right to the key size, raised to `e` mod `n`, written as 128 hex digits, concatenated.
    func sign(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        let size = rsa.blockSize
        var out = ""
        var start = 0
        while start < bytes.count {
            var block = Array(bytes[start..<min(start + size, bytes.count)])
            block += Array(repeating: 0, count: size - block.count)
            guard let c = rsa.encrypt(block) else { return nil }
            out += c.map { String(format: "%02x", $0) }.joined()
            start += size
        }
        return out
    }

    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// AES-128-CBC with PKCS#7 padding; the key and IV are the UTF-8 bytes of 16-character strings.
    static func aes(_ input: [UInt8], key: String, iv: String, encrypt: Bool) -> [UInt8]? {
        let k = Array(key.utf8), v = Array(iv.utf8)
        guard k.count == kCCKeySizeAES128, v.count == kCCBlockSizeAES128 else { return nil }
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionPKCS7Padding), k, k.count, v, input, input.count,
                    o.baseAddress, o.count, &moved)
        }
        guard status == kCCSuccess else { return nil }
        return Array(out.prefix(moved))
    }
}

private extension Array where Element == UInt8 {
    var base64: String { Data(self).base64EncodedString() }
}
