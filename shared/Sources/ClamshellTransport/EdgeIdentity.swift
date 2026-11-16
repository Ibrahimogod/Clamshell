#if os(macOS)
import Foundation
import Security

/// The Mac's outer TLS identity for the 443 listener (ADR-0003): self-signed, made at first launch with the
/// system's `/usr/bin/openssl` (no outside service), kept as a PKCS#12 file next to the host's data and
/// imported in memory only (it never enters a keychain). Low value by design: Noise carries the security.
/// Replaced after a year.
public enum EdgeIdentity {
    static let password = "clamshell-edge"

    public static func loadOrCreate(directory: URL) throws -> SecIdentity {
        let p12 = directory.appendingPathComponent("edge-identity.p12")
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: p12.path), let made = attrs[.creationDate] as? Date,
           Date().timeIntervalSince(made) < 360 * 86_400, let id = try? load(p12) {
            return id
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.removeItem(at: p12)
        let tmp = fm.temporaryDirectory.appendingPathComponent("clamshell-edge-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let key = tmp.appendingPathComponent("k.pem").path, cert = tmp.appendingPathComponent("c.pem").path
        // LibreSSL's defaults: a named-curve P-256 key and the default PKCS#12 ciphers are what
        // SecPKCS12Import reads (a `-newkey ec` key or 3DES PBE options make it fail).
        try run(["ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key])
        try run(["req", "-x509", "-new", "-key", key, "-out", cert, "-days", "400", "-subj", "/CN=localhost"])
        try run(["pkcs12", "-export", "-inkey", key, "-in", cert, "-out", p12.path, "-passout", "pass:\(password)"])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        return try load(p12)
    }

    static func load(_ url: URL) throws -> SecIdentity {
        let data = try Data(contentsOf: url)
        var items: CFArray?
        let opts: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(data as CFData, opts as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let any = first[kSecImportItemIdentity as String] else { throw TransportError.listenerFailed("TLS identity import failed (\(status))") }
        return any as! SecIdentity  // swiftlint:disable:this force_cast — CF type, the cast can't fail
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw TransportError.listenerFailed("openssl \(args[0]) failed") }
    }
}
#endif
