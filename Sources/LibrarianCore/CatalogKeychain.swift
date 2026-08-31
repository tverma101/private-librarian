import Foundation
import Security

/// Stores the SQLCipher catalog key in macOS's data-protection Keychain as a
/// generic password item. The key is generated once (32 random bytes) and
/// never leaves the Keychain except to hand to the Catalog at open time.
public enum CatalogKeychain {

    public static let service = "com.tejas.private-librarian.catalog"
    public static let account = "catalog-v1"

    /// Keep one result per process. Besides avoiding needless Security-server
    /// traffic, this is important for SwiftUI/AppKit lifecycle churn: a
    /// failed keychain lookup must not turn into a prompt loop while the app
    /// is still alive. A relaunch is the explicit retry boundary.
    private final class LookupCache: @unchecked Sendable {
        let lock = NSLock()
        var key: Data?
        var failure: KeyError?
    }

    private static let lookupCache = LookupCache()

    public enum KeyError: Error, CustomStringConvertible {
        case generationFailed
        case osStatus(OSStatus)
        case unexpectedFormat

        public var description: String {
            switch self {
            case .generationFailed: return "failed to generate catalog key"
            case .osStatus(let s):
                switch s {
                case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                    return "catalog Keychain access was denied; choose Migrate Existing Catalog and then Always Allow once"
                case errSecMissingEntitlement:
                    return "catalog Keychain access is missing the app's signed entitlement"
                default:
                    let message = (SecCopyErrorMessageString(s, nil) as String?)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let message, !message.isEmpty {
                        return "keychain error \(s): \(message)"
                    }
                    return "keychain error \(s)"
                }
            case .unexpectedFormat: return "keychain item has unexpected format"
            }
        }
    }

    /// Load the app-owned key or create + store a fresh one. If an older
    /// development CLI created the item in macOS's legacy login keychain,
    /// migrate the same key once into the data-protection keychain instead of
    /// rotating the key and making the encrypted catalog unreadable.
    public static func loadOrCreate() throws -> Data {
        lookupCache.lock.lock()
        defer { lookupCache.lock.unlock() }
        if let key = lookupCache.key { return key }
        if let failure = lookupCache.failure { throw failure }

        do {
            let key: Data
            if let existing = try load() {
                key = existing
            } else if let legacy = try loadLegacy() {
                key = legacy
                try save(key)
            } else {
                var bytes = [UInt8](repeating: 0, count: 32)
                let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
                guard rc == errSecSuccess else { throw KeyError.generationFailed }
                key = Data(bytes)
                try save(key)
            }
            lookupCache.key = key
            return key
        } catch let error as KeyError {
            lookupCache.failure = error
            throw error
        }
    }

    /// Create a key in the app-owned data-protection Keychain without ever
    /// consulting the legacy login-keychain item. The GUI uses this path for
    /// a genuinely new catalog so first launch is never blocked by a legacy
    /// access prompt.
    public static func createAppOwned() throws -> Data {
        lookupCache.lock.lock()
        defer { lookupCache.lock.unlock() }
        if let key = lookupCache.key { return key }
        if let failure = lookupCache.failure { throw failure }

        do {
            if let existing = try load() {
                lookupCache.key = existing
                return existing
            }
            var bytes = [UInt8](repeating: 0, count: 32)
            let rc = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            guard rc == errSecSuccess else { throw KeyError.generationFailed }
            let key = Data(bytes)
            try save(key)
            lookupCache.key = key
            return key
        } catch let error as KeyError {
            lookupCache.failure = error
            throw error
        }
    }

    /// Explicitly migrate the old login-keychain item into the app-owned
    /// data-protection Keychain. This is intentionally separate from normal
    /// startup: reading an item created by an older unsigned build can invoke
    /// a macOS approval prompt, so only a visible user action may request it.
    /// Returns nil when no legacy item exists and never creates a replacement
    /// key for an existing encrypted catalog.
    public static func migrateLegacy() throws -> Data? {
        lookupCache.lock.lock()
        defer { lookupCache.lock.unlock() }
        if let key = lookupCache.key { return key }
        if let failure = lookupCache.failure { throw failure }

        do {
            guard let legacy = try loadLegacy() else { return nil }
            try save(legacy)
            lookupCache.key = legacy
            return legacy
        } catch let error as KeyError {
            lookupCache.failure = error
            throw error
        }
    }

    public static func load() throws -> Data? {
        try load(useDataProtectionKeychain: true)
    }

    private static func loadLegacy() throws -> Data? {
        // This is intentionally the only legacy lookup. A successful read is
        // immediately copied to the app-owned data-protection keychain; a
        // denial is cached by loadOrCreate() for the rest of this process so
        // SwiftUI lifecycle callbacks cannot show a prompt loop.
        try load(useDataProtectionKeychain: false)
    }

    private static func load(useDataProtectionKeychain: Bool) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var scopedQuery = query
        if useDataProtectionKeychain {
            scopedQuery[kSecUseDataProtectionKeychain as String] = true
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(scopedQuery as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
        guard let data = out as? Data, data.count == 32 else {
            throw KeyError.unexpectedFormat
        }
        return data
    }

    private static func save(_ key: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
    }

    /// Destroy the stored key (used by tests with a test-scoped service name).
    public static func destroy(service: String = service) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.osStatus(status)
        }

        // Keep the historical API's destroy semantics for callers cleaning up
        // a test-scoped service, while normal runtime migration never deletes
        // the legacy item.
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        let legacyStatus = SecItemDelete(legacyQuery as CFDictionary)
        guard legacyStatus == errSecSuccess || legacyStatus == errSecItemNotFound else {
            throw KeyError.osStatus(legacyStatus)
        }

        if service == Self.service {
            lookupCache.lock.lock()
            lookupCache.key = nil
            lookupCache.failure = nil
            lookupCache.lock.unlock()
        }
    }
}
