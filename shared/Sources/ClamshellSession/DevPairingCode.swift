import Foundation

/// M1-only development pairing (removed in M3, replaced by QR + SAS pairing, ADR-0014).
///
/// The Mac shows `CLAMDEV1:<base64url(macPublicKey ‖ psk)>`; you give it to the phone as the
/// Xcode launch argument/env var `CLAMSHELL_DEV_CODE` or by pasting. The PSK is secret: anyone with
/// this code can connect while the Mac is in development-pairing mode.
public struct DevPairingCode: Equatable, Sendable {
    public static let prefix = "CLAMDEV1:"
    public let macPublicKey: [UInt8]
    public let psk: [UInt8]

    public init(macPublicKey: [UInt8], psk: [UInt8]) {
        self.macPublicKey = macPublicKey
        self.psk = psk
    }

    public static func generatePSK() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }

    public var string: String {
        let b64 = Data(macPublicKey + psk).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self.prefix + b64
    }

    public init?(string raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix(Self.prefix) else { return nil }
        var b64 = String(s.dropFirst(Self.prefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64), data.count == 64 else { return nil }
        let bytes = [UInt8](data)
        macPublicKey = Array(bytes[0..<32])
        psk = Array(bytes[32..<64])
    }
}
