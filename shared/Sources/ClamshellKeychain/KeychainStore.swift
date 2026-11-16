import Foundation
import Security

/// Small generic-password store for secrets that must never leave this device (ADR-0014):
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, not synchronizable, so no iCloud Keychain.
///
/// On macOS it prefers the data-protection keychain (needs a team-signed app). An unsigned local build
/// gets `errSecMissingEntitlement` there, so it falls back to the login keychain.
public struct KeychainStore: Sendable {
    public enum KeychainError: Error, Equatable, Sendable { case status(OSStatus) }

    public let service: String

    public init(service: String) { self.service = service }

    public func data(_ account: String) throws -> Data? {
        for dataProtection in Self.modes {
            var q = base(account, dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            switch status {
            case errSecSuccess: return out as? Data
            case errSecItemNotFound: continue
            case errSecMissingEntitlement: continue
            default: throw KeychainError.status(status)
            }
        }
        return nil
    }

    public func set(_ value: Data, for account: String) throws {
        var lastError: OSStatus = errSecSuccess
        for dataProtection in Self.modes {
            let q = base(account, dataProtection: dataProtection)
            let attrs: [String: Any] = [kSecValueData as String: value,
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound {
                var add = q
                attrs.forEach { add[$0.key] = $0.value }
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess { return }
            lastError = status
            if status != errSecMissingEntitlement { break }
        }
        throw KeychainError.status(lastError)
    }

    public func delete(_ account: String) throws {
        for dataProtection in Self.modes {
            let status = SecItemDelete(base(account, dataProtection: dataProtection) as CFDictionary)
            guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else { throw KeychainError.status(status) }
        }
    }

    /// Returns the stored value, or creates, stores and returns a new one.
    public func dataOrCreate(_ account: String, _ make: () -> Data) throws -> Data {
        if let d = try data(account) { return d }
        let d = make()
        try set(d, for: account)
        return d
    }

    #if os(macOS)
    private static let modes = [true, false]
    #else
    private static let modes = [true]
    #endif

    private func base(_ account: String, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecAttrSynchronizable as String: false]
        #if os(macOS)
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }
}
