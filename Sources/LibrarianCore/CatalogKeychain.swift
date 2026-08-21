import Foundation
import Security

/// Stores the SQLCipher catalog key in the macOS Keychain as a generic
/// password item. The key is generated once (32 random bytes) and never
/// leaves the Keychain except to hand to the Catalog at open time.
public enum CatalogKeychain {

    public static let service = "com.tejas.private-librarian.catalog"
    public static let account = "catalog-v1"

    public enum KeyError: Error, CustomStringConvertible {
        case generationFailed
        case osStatus(OSStatus)
        case unexpectedFormat

        public var description: String {
            switch self {
            case .generationFailed: return "failed to generate catalog key"
            case .osStatus(let s): return "keychain error \(s)"
            case .unexpectedFormat: return "keychain item has unexpected format"
            }
        }
    }

    /// Load the existing key or create + store a fresh one. Returns raw key data.
    public static func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard rc == errSecSuccess else { throw KeyError.generationFailed }
        let key = Data(bytes)
        try save(key)
        return key
    }

    public static func load() throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
        guard let data = out as? Data else { throw KeyError.unexpectedFormat }
        return data
    }

    private static func save(_ key: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
    }

    /// Destroy the stored key (used by tests with a test-scoped service name).
    public static func destroy(service: String = service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.osStatus(status)
        }
    }
}
