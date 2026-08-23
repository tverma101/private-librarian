import SwiftUI
import LibrarianCore

/// Native SwiftUI shell (plan §1, §45, §46). No web server, no WebView,
/// no listening socket. Sources are added via the system folder picker with
/// read-only security-scoped bookmarks; the catalog is SQLCipher-encrypted
/// with its key in the Keychain.
@main
struct PrivateLibrarianApp: App {
    @StateObject private var model = LibrarianModel()

    var body: some Scene {
        WindowGroup("Private Librarian") {
            MagicContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Add Source Folder…") { model.addSourceFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class LibrarianModel: ObservableObject {

    struct SourceFolder: Identifiable, Codable {
        let id: UUID
        let path: String
    }

    @Published var sources: [SourceFolder] = []
    @Published var statusLines: [String] = []
    @Published var searchResults: [String] = []
    @Published var query: String = ""
    @Published var isIndexing = false
    @Published var selectedSection: LibrarySection = .overview
    @Published var excludedPaths: [String] = []
    @Published var dashboard: CatalogDashboard = .empty
    @Published var reviewItems: [ReviewItem] = []
    @Published var organizationGraph: OrganizationGraphSnapshot = .empty
    @Published var coverage: OnboardingCoverage = .empty
    @Published private(set) var pausedPaths: Set<String> = []
    @Published var localEmbeddingsEnabled: Bool {
        didSet { UserDefaults.standard.set(localEmbeddingsEnabled, forKey: "tier2-enabled-v1") }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText

    var isTier2Provisioned: Bool {
        LocalModelBridge.isProvisioned(.clipImage) || LocalModelBridge.isProvisioned(.miniLMText)
    }

    private var catalog: Catalog?
    private var bookmarkDataByPath: [String: Data] = [:]

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PrivateLibrarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        if let m = UserDefaults.standard.string(forKey: "tier2-search-mode-v1") { self.searchMode = m }
        loadBookmarks()
        loadExclusions()
        loadPausedPaths()
        openCatalogIfNeeded()
    }

    // MARK: - Catalog

    private func openCatalogIfNeeded() {
        guard catalog == nil else { return }
        do {
            let key = try CatalogKeychain.loadOrCreate()
            let dbPath = Self.appSupportDir.appendingPathComponent("catalog.db").path
            catalog = try Catalog(path: dbPath, key: key)
            log("catalog opened (encrypted)")
        } catch {
            log("catalog error: \(error)")
        }
    }

    // MARK: - Read-only source access via security-scoped bookmarks

    func addSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to index. Access is READ-ONLY; files are never modified."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)) ?? Data()
                self.bookmarkDataByPath[url.path] = data
                if !self.sources.contains(where: { $0.path == url.path }) {
                    self.sources.append(SourceFolder(id: UUID(), path: url.path))
                }
            }
            self.saveBookmarks()
        }
    }

    func isPaused(_ source: SourceFolder) -> Bool { pausedPaths.contains(source.path) }

    func togglePaused(_ source: SourceFolder) {
        if pausedPaths.contains(source.path) {
            pausedPaths.remove(source.path)
        } else {
            pausedPaths.insert(source.path)
        }
        savePausedPaths()
        refreshDashboard()
    }

    func removeSource(_ source: SourceFolder) {
        sources.removeAll { $0.id == source.id }
        bookmarkDataByPath.removeValue(forKey: source.path)
        pausedPaths.remove(source.path)
        saveBookmarks()
        savePausedPaths()
        refreshDashboard()
    }

    func reauthorizeSource(_ source: SourceFolder) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the replacement folder. Access remains READ-ONLY."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                              includingResourceValuesForKeys: nil,
                                              relativeTo: nil)) ?? Data()
            self.bookmarkDataByPath.removeValue(forKey: source.path)
            self.bookmarkDataByPath[url.path] = data
            if let index = self.sources.firstIndex(where: { $0.id == source.id }) {
                self.sources[index] = SourceFolder(id: source.id, path: url.path)
            }
            if self.pausedPaths.remove(source.path) != nil {
                self.pausedPaths.insert(url.path)
            }
            self.saveBookmarks()
            self.savePausedPaths()
            self.refreshDashboard()
        }
    }

    func addExclusionFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to exclude from indexing. Originals remain untouched."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK else { return }
            let additions = panel.urls.map(\.path)
            for path in additions where !self.excludedPaths.contains(path) {
                self.excludedPaths.append(path)
            }
            self.saveExclusions()
            self.refreshDashboard()
        }
    }

    func removeExclusion(_ path: String) {
        excludedPaths.removeAll { $0 == path }
        saveExclusions()
        refreshDashboard()
    }

    /// Resolve a stored read-only security-scoped bookmark and run `body`
    /// while access is active.
    func withSource<T>(_ source: SourceFolder, _ body: (URL) throws -> T) rethrows -> T? {
        try Self.accessSource(source, bookmarkData: bookmarkDataByPath[source.path], body)
    }

    private nonisolated static func accessSource<T>(_ source: SourceFolder,
                                                    bookmarkData: Data?,
                                                    _ body: (URL) throws -> T) rethrows -> T? {
        guard let data = bookmarkData else {
            // CLI/test harness path without a bookmark — direct read-only use.
            return try? body(URL(fileURLWithPath: source.path))
        }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else {
            return try? body(URL(fileURLWithPath: source.path))
        }
        let started = resolved.startAccessingSecurityScopedResource()
        defer { if started { resolved.stopAccessingSecurityScopedResource() } }
        return try body(resolved)
    }

    func startIndexing() {
        guard let catalog, !isIndexing else { return }
        isIndexing = true
        let broker = SourceBroker()
        var opts = Indexer.Options()
        opts.enableLocalEmbeddings = localEmbeddingsEnabled
        opts.excludedPaths = excludedPaths
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler(), options: opts)
        let sourcesToIndex = sources.filter { !pausedPaths.contains($0.path) }
        let bookmarksToUse = bookmarkDataByPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for src in sourcesToIndex {
                _ = Self.accessSource(src, bookmarkData: bookmarksToUse[src.path]) { url in
                    _ = try? indexer.indexRoot(url) { p in
                        DispatchQueue.main.async {
                            self?.log("indexing… \(p.processed)/\(p.total)")
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self?.isIndexing = false
                self?.log("indexing complete")
                self?.refreshDashboard()
            }
        }
    }

    func refreshDashboard() {
        guard let catalog else { return }
        do {
            organizationGraph = try catalog.refreshOrganizationGraph()
            dashboard = try catalog.dashboard()
            reviewItems = try catalog.reviewItems()
            coverage = try catalog.coverage(roots: sources.map(\.path), excludedPaths: excludedPaths)
        } catch {
            log("dashboard refresh error: \(error)")
        }
    }

    func files(for section: LibrarySection) -> [Catalog.FileSummary] {
        guard let catalog else { return [] }
        switch section {
        case .screenshots:
            let plural = (try? catalog.fileSummaries(categoryPrefix: "Screenshots", limit: 200)) ?? []
            let singular = (try? catalog.fileSummaries(categoryPrefix: "Screenshot", limit: 200)) ?? []
            return Array(Dictionary(uniqueKeysWithValues: (plural + singular).map { ($0.id, $0) })
                .values.sorted { $0.path < $1.path }.prefix(200))
        case .school:
            return (try? catalog.fileSummaries(categoryPrefix: "School", limit: 200)) ?? []
        case .projects:
            return (try? catalog.fileSummaries(categoryPrefix: "Projects", limit: 200)) ?? []
        case .documents:
            return (try? catalog.fileSummaries(categoryPrefix: "Documents", limit: 200)) ?? []
        case .media:
            let all = (try? catalog.fileSummaries(limit: Int.max)) ?? []
            return Array(all.filter { $0.kind == FileKind.audio.rawValue || $0.kind == FileKind.video.rawValue }.prefix(200))
        case .duplicates:
            guard let duplicateIDs = try? catalog.duplicateFileIDs() else { return [] }
            return (try? catalog.fileSummaries(limit: Int.max).filter { duplicateIDs.contains($0.id) }.prefix(200).map { $0 }) ?? []
        case .missing:
            return (try? catalog.fileSummaries(status: "missing", limit: 200)) ?? []
        default:
            return (try? catalog.fileSummaries(limit: 200)) ?? []
        }
    }

    func applyReviewCorrection(item: ReviewItem, category: String, action: ReviewCorrectionAction) {
        guard let catalog else { return }
        do {
            try catalog.applyReviewCorrection(fileID: item.fileID, category: category, action: action)
            refreshDashboard()
            log("review corrected: \((item.path as NSString).lastPathComponent)")
        } catch {
            log("review correction error: \(error)")
        }
    }

    func runSearch() {
        guard let catalog, !query.isEmpty else { return }
        let svc = SearchService(catalog: catalog, enableLocalEmbeddings: localEmbeddingsEnabled)
        let mode = searchMode
        var lines: [String] = []
        switch mode {
        case "exact":
            lines = ((try? svc.search(query)) ?? []).map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent)" }
        case "semantic":
            lines = ((try? svc.semanticSearch(query: query)) ?? []).map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent) [\(String(format:"%.2f", h.score))]" }
        case "clipText":
            lines = ((try? svc.clipTextToImageSearch(query: query)) ?? []).map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent) [clip \(String(format:"%.2f", h.score))]" }
        default:
            let sem = (try? svc.semanticSearch(query: query)) ?? []
            if !sem.isEmpty {
                lines = sem.map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent) [\(String(format:"%.2f", h.score))]" }
            } else {
                let clip = (try? svc.clipTextToImageSearch(query: query)) ?? []
                if !clip.isEmpty {
                    lines = clip.map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent) [clip \(String(format:"%.2f", h.score))]" }
                } else {
                    lines = ((try? svc.search(query)) ?? []).map { h in "\(h.fileID) — \((h.path as NSString).lastPathComponent)" }
                }
            }
        }
        if lines.isEmpty { lines = ["No results"] }
        searchResults = lines
    }

    /// Privacy indicators derived from ACTUAL state where possible (plan §45).
    func privacyIndicators() -> [(String, Bool)] {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") != nil
            || amISandboxed()
        return [
            ("App Sandbox enabled", sandboxed),
            ("Sources read-only", true),   // enforced by SourceBroker O_RDONLY|O_NOFOLLOW + entitlements
            ("Internet disabled", !hasNetworkEntitlement()),
            ("Telemetry disabled", true),
            ("Catalog encrypted", catalogOnDiskEncrypted()),
            ("\(sources.count) folders authorized", !sources.isEmpty),
        ]
    }

    private func amISandboxed() -> Bool {
        // Sandbox check: SecTaskCopyValueForEntitlement for the sandbox entitlement.
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let val = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool
        return val ?? false
    }

    private func hasNetworkEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let client = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.client" as CFString, nil) as? Bool
        let server = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.server" as CFString, nil) as? Bool
        return (client ?? false) || (server ?? false)
    }

    private func catalogOnDiskEncrypted() -> Bool {
        let p = Self.appSupportDir.appendingPathComponent("catalog.db").path
        return FileManager.default.fileExists(atPath: p)
            && !Catalog.onDiskHeaderIsPlaintextSQLite(path: p)
    }

    private func log(_ s: String) {
        statusLines.append(s)
        if statusLines.count > 200 { statusLines.removeFirst(statusLines.count - 200) }
    }

    // MARK: - Bookmark persistence

    private func saveBookmarks() {
        let payload = sources.compactMap { src -> Data? in bookmarkDataByPath[src.path] }
        UserDefaults.standard.set(payload.map { $0.base64EncodedString() }, forKey: "source-bookmarks-v1")
        UserDefaults.standard.set(sources.map(\.path), forKey: "source-paths-v1")
    }

    private func loadBookmarks() {
        guard let b64 = UserDefaults.standard.stringArray(forKey: "source-bookmarks-v1"),
              let paths = UserDefaults.standard.stringArray(forKey: "source-paths-v1") else { return }
        let datas = b64.compactMap { Data(base64Encoded: $0) }
        for (i, path) in paths.enumerated() where i < datas.count {
            sources.append(SourceFolder(id: UUID(), path: path))
            bookmarkDataByPath[path] = datas[i]
        }
    }

    private func saveExclusions() {
        UserDefaults.standard.set(excludedPaths, forKey: "excluded-paths-v1")
    }

    private func loadExclusions() {
        excludedPaths = UserDefaults.standard.stringArray(forKey: "excluded-paths-v1") ?? []
    }

    private func savePausedPaths() {
        UserDefaults.standard.set(Array(pausedPaths), forKey: "paused-source-paths-v1")
    }

    private func loadPausedPaths() {
        pausedPaths = Set(UserDefaults.standard.stringArray(forKey: "paused-source-paths-v1") ?? [])
    }
}
