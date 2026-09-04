import Foundation
import LocalAuthentication
import Security

/// Stores the SQLCipher catalog key in an app-owned macOS Keychain item. The
/// key is generated once (32 random bytes) and never leaves the Keychain
/// except to hand to the Catalog at open time.
///
/// The distributable is a profile-free, sandboxed SwiftPM app. macOS requires
/// the signed application-identifier entitlement for the data-protection
/// Keychain, and manually adding that restricted entitlement makes an
/// otherwise launchable bundle fail AMFI without a matching provisioning
/// profile. This app therefore uses its own stable service name in the
/// traditional Keychain, whose access control is tied to the stable signed
/// application identity and does not require that restricted entitlement.
public enum CatalogKeychain {

    /// New app-owned namespace. Keep this distinct from the service used by
    /// older unsigned CLI builds so a fresh launch never probes that item.
    public static let service = "com.tejas.private-librarian.catalog.app-v2"
    public static let account = "catalog-v1"

    /// Legacy service used by the pre-packaging CLI. It is accessed only by
    /// the explicit migration action in the GUI.
    private static let legacyService = "com.tejas.private-librarian.catalog"

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
                    return "catalog Keychain access was denied; relaunch the app before retrying"
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
    /// migrate the same key once into the app-owned namespace instead of
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

    /// Create a key in the app-owned Keychain without ever
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
    /// Keychain namespace. This is intentionally separate from normal
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
        // Startup must never present an authentication sheet. If an old ACL
        // does not trust this signed bundle, return the error to the visible
        // recovery UI and cache it for this process instead of prompting on
        // every SwiftUI lifecycle callback.
        try load(service: service, allowsInteraction: false)
    }

    private static func loadLegacy() throws -> Data? {
        // This is intentionally the only legacy lookup. A successful read is
        // immediately copied to the app-owned Keychain namespace; a
        // denial is cached by loadOrCreate() for the rest of this process so
        // SwiftUI lifecycle callbacks cannot show a prompt loop.
        try load(service: legacyService, allowsInteraction: true)
    }

    private static func load(service: String, allowsInteraction: Bool) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if !allowsInteraction {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
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
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeyError.osStatus(status) }
    }

    /// Destroy the stored key (used by tests with a test-scoped service name).
    public static func destroy(service: String = service) throws {
        let services = service == Self.service ? [Self.service, Self.legacyService] : [service]
        for currentService in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: currentService,
            ]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeyError.osStatus(status)
            }
        }

        // Keep the historical API's destroy semantics for callers cleaning up
        // a test-scoped service, while normal runtime migration never deletes
        // the legacy item.
        if service == Self.service {
            lookupCache.lock.lock()
            lookupCache.key = nil
            lookupCache.failure = nil
            lookupCache.lock.unlock()
        }
    }

    /// Delete ONLY the app-owned catalog key item and clear the process
    /// cache. This is the explicit recovery path for an item whose Keychain
    /// ACL no longer trusts this app's code signature (ad-hoc rebuild churn):
    /// the encrypted catalog data on disk stays in place, so the caller must
    /// move it aside before this unless the library is intentionally abandoned.
    /// The legacy login-keychain item is never touched here.
    public static func destroyAppOwned() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeyError.osStatus(status)
        }
        lookupCache.lock.lock()
        lookupCache.key = nil
        lookupCache.failure = nil
        lookupCache.lock.unlock()
    }
}
