import Foundation
import LibrarianCore

/// Owns one resolved security-scoped bookmark for as long as the caller needs
/// it. The lease fails closed for missing, corrupt, or stale bookmarks and
/// balances start/stop access automatically.
final class SecurityScopedBookmarkLease: @unchecked Sendable {
    enum LeaseError: Error, LocalizedError {
        case missingBookmark
        case invalidBookmark
        case staleBookmark

        var errorDescription: String? {
            switch self {
            case .missingBookmark: return "Saved folder permission is missing. Re-authorize the folder."
            case .invalidBookmark: return "Saved folder permission could not be restored. Re-authorize the folder."
            case .staleBookmark: return "Saved folder permission is stale. Re-authorize the folder."
            }
        }
    }

    let url: URL
    private let started: Bool

    init(bookmarkData: Data?) throws {
        guard let bookmarkData, !bookmarkData.isEmpty else { throw LeaseError.missingBookmark }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            throw LeaseError.invalidBookmark
        }
        guard !stale else { throw LeaseError.staleBookmark }
        self.url = resolved
        self.started = resolved.startAccessingSecurityScopedResource()
    }

    deinit {
        if started { url.stopAccessingSecurityScopedResource() }
    }

    /// Convert a catalog path under the originally authorized root to the
    /// equivalent path under the resolved bookmark URL. This keeps previews
    /// fail-closed without requiring a separate bookmark for every child file.
    func targetURL(for requestedPath: String, originalRootPath: String) -> URL? {
        let root = originalRootPath.hasSuffix("/") ? String(originalRootPath.dropLast()) : originalRootPath
        guard requestedPath == root || SourceBroker.isPath(requestedPath, under: root) else { return nil }
        if requestedPath == root { return url }
        let prefix = root + "/"
        guard requestedPath.hasPrefix(prefix) else { return nil }
        return url.appendingPathComponent(String(requestedPath.dropFirst(prefix.count)))
    }
}

/// Local-only Whisper configuration used by the app. Nothing is downloaded or
/// installed automatically. Users opt in only after both the executable and
/// model already exist on disk.
enum AppLocalTranscription {
    static let enabledDefaultsKey = "local-transcription-enabled-v1"

    static var executablePath: String {
        if let override = ProcessInfo.processInfo.environment["LIBRARIAN_WHISPER_CLI"], !override.isEmpty {
            return override
        }
        let candidates = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ?? candidates[0]
    }

    static var modelPath: String {
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

    static var preflight: WhisperCLITranscriptionProvider.Preflight {
        WhisperCLITranscriptionProvider.preflight(
            executablePath: executablePath,
            modelPath: modelPath)
    }

    static var isAvailable: Bool {
        if case .available = preflight { return true }
        return false
    }

    static var statusText: String {
        switch preflight {
        case .available:
            return "Local transcription ready"
        case .unavailable(let reason):
            return reason
        }
    }

    static func providerIfAvailable() -> WhisperCLITranscriptionProvider? {
        guard isAvailable else { return nil }
        return WhisperCLITranscriptionProvider(
            executablePath: executablePath,
            modelPath: modelPath)
    }
}
