import Foundation
import LibrarianCore

/// Owns one resolved security-scoped bookmark for as long as the caller needs
/// it. Missing, corrupt, and stale bookmarks fail closed; there is no raw-path
/// fallback in the packaged app.
public final class SecurityScopedBookmarkLease: @unchecked Sendable {
    public enum LeaseError: Error, LocalizedError, Equatable {
        case missingBookmark
        case invalidBookmark
        case staleBookmark
        case accessDenied

        public var errorDescription: String? {
            switch self {
            case .missingBookmark: return "Saved folder permission is missing. Re-authorize the folder."
            case .invalidBookmark: return "Saved folder permission could not be restored. Re-authorize the folder."
            case .staleBookmark: return "Saved folder permission is stale. Re-authorize the folder."
            case .accessDenied: return "Saved folder permission could not be activated. Re-authorize the folder."
            }
        }
    }

    struct ResolvedBookmark: Sendable {
        let url: URL
        let isStale: Bool
    }

    typealias Resolver = @Sendable (Data) throws -> ResolvedBookmark
    typealias BeginAccess = @Sendable (URL) -> Bool
    typealias EndAccess = @Sendable (URL) -> Void

    public let url: URL
    private let started: Bool
    private let endAccess: EndAccess

    public convenience init(bookmarkData: Data?) throws {
        try self.init(
            bookmarkData: bookmarkData,
            resolver: { data in try Self.resolveSystemBookmark(data) },
            beginAccess: { $0.startAccessingSecurityScopedResource() },
            endAccess: { $0.stopAccessingSecurityScopedResource() }
        )
    }

    /// Internal injection point used by the app-support regression tests. The
    /// production app always uses the public bookmark-only initializer above.
    init(bookmarkData: Data?, resolver: @escaping Resolver,
         beginAccess: @escaping BeginAccess, endAccess: @escaping EndAccess) throws {
        guard let bookmarkData, !bookmarkData.isEmpty else { throw LeaseError.missingBookmark }
        let resolved: ResolvedBookmark
        do {
            resolved = try resolver(bookmarkData)
        } catch let error as LeaseError {
            throw error
        } catch {
            throw LeaseError.invalidBookmark
        }
        guard !resolved.isStale else { throw LeaseError.staleBookmark }
        guard beginAccess(resolved.url) else { throw LeaseError.accessDenied }
        self.url = resolved.url
        self.started = true
        self.endAccess = endAccess
    }

    deinit {
        if started { endAccess(url) }
    }

    /// Convert a catalog path under the originally authorized root to the
    /// equivalent path under the resolved bookmark URL. This keeps previews
    /// fail-closed without requiring a bookmark for every child file.
    public func targetURL(for requestedPath: String, originalRootPath: String) -> URL? {
        let root = originalRootPath.hasSuffix("/") ? String(originalRootPath.dropLast()) : originalRootPath
        guard requestedPath == root || SourceBroker.isPath(requestedPath, under: root) else { return nil }
        if requestedPath == root { return url }
        let prefix = root + "/"
        guard requestedPath.hasPrefix(prefix) else { return nil }
        return url.appendingPathComponent(String(requestedPath.dropFirst(prefix.count)))
    }

    private static func resolveSystemBookmark(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            throw LeaseError.invalidBookmark
        }
        return ResolvedBookmark(url: resolved, isStale: stale)
    }
}

/// Local-only Whisper configuration used by the app. Nothing is downloaded or
/// installed automatically. Users opt in only after both executable and model
/// already exist and pass preflight.
public enum AppLocalTranscription {
    public static let enabledDefaultsKey = "local-transcription-enabled-v1"

    public static var executablePath: String {
        if let override = ProcessInfo.processInfo.environment["LIBRARIAN_WHISPER_CLI"], !override.isEmpty {
            return override
        }
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? candidates[0]
    }

    public static var modelPath: String {
        if let override = ProcessInfo.processInfo.environment["LIBRARIAN_WHISPER_MODEL"], !override.isEmpty {
            return override
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("PrivateLibrarian", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("ggml-base.en.bin")
            .path
    }

    public static func preflight(executablePath: String, modelPath: String)
        -> WhisperCLITranscriptionProvider.Preflight {
        WhisperCLITranscriptionProvider.preflight(
            executablePath: executablePath,
            modelPath: modelPath)
    }

    public static var preflight: WhisperCLITranscriptionProvider.Preflight {
        preflight(executablePath: executablePath, modelPath: modelPath)
    }

    public static var isAvailable: Bool {
        if case .available = preflight { return true }
        return false
    }

    public static var statusText: String {
        switch preflight {
        case .available:
            return "Local transcription ready"
        case .unavailable(let reason):
            return reason
        }
    }

    public static func providerIfAvailable() -> WhisperCLITranscriptionProvider? {
        providerIfAvailable(executablePath: executablePath, modelPath: modelPath)
    }

    public static func providerIfAvailable(executablePath: String, modelPath: String)
        -> WhisperCLITranscriptionProvider? {
        guard case .available = preflight(executablePath: executablePath, modelPath: modelPath) else {
            return nil
        }
        return WhisperCLITranscriptionProvider(
            executablePath: executablePath,
            modelPath: modelPath)
    }

    /// Pure app-configuration seam. The SwiftUI setting feeds this policy, and
    /// tests can use explicit fixture paths instead of relying on a developer
    /// machine having Whisper installed.
    public static func selection(
        enabled: Bool,
        executablePath: String? = nil,
        modelPath: String? = nil
    ) -> (enabled: Bool, provider: any SpeechTranscriptionProvider) {
        let executable = executablePath ?? self.executablePath
        let model = modelPath ?? self.modelPath
        guard enabled,
              let provider = providerIfAvailable(executablePath: executable, modelPath: model) else {
            return (false, DisabledSpeechTranscriptionProvider())
        }
        return (true, provider)
    }

    /// Apply the app's opt-in decision directly to Indexer.Options and return
    /// the matching provider. This is the seam used to prove that the UI-level
    /// setting produces the same configuration the Indexer receives.
    @discardableResult
    public static func configure(
        options: inout Indexer.Options,
        enabled: Bool,
        executablePath: String? = nil,
        modelPath: String? = nil
    ) -> any SpeechTranscriptionProvider {
        let selected = selection(
            enabled: enabled,
            executablePath: executablePath,
            modelPath: modelPath
        )
        options.enableLocalASR = selected.enabled
        return selected.provider
    }
}
