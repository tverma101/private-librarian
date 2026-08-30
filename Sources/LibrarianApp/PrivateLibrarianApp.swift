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

    struct SourceFolder: Identifiable, Codable, Sendable {
        let id: UUID
        let path: String
    }

    struct PreviewRequest: Sendable, Equatable {
        let path: String
        let sourceRoot: String
        let bookmarkData: Data?
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
    @Published var learnedRules: [LearnedRule] = []
    @Published var similarityClusters: [SimilarityCluster] = []
    @Published var organizationGraph: OrganizationGraphSnapshot = .empty
    @Published var smartGroups: [SmartOrganizationGroup] = []
    @Published var coverage: OnboardingCoverage = .empty
    @Published private(set) var pausedPaths: Set<String> = []
    @Published private(set) var liveIndexRunning = false
    @Published private(set) var livePendingEvents = 0
    @Published private(set) var sourcesNeedingReauthorization: Set<String> = []
    @Published var localTranscriptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localTranscriptionEnabled, forKey: AppLocalTranscription.enabledDefaultsKey)
            restartLiveCoordinator()
            refreshDashboard()
            startIndexing()
        }
    }
    @Published var localEmbeddingsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localEmbeddingsEnabled, forKey: "tier2-enabled-v1")
            restartLiveCoordinator()
            refreshDashboard()
        }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText

    var isTier2Provisioned: Bool {
        CoreMLMobileCLIPProvider.isAvailable
            || LocalModelBridge.isProvisioned(.clipImage)
            || LocalModelBridge.isProvisioned(.miniLMText)
    }

    var isLocalTranscriptionAvailable: Bool { AppLocalTranscription.isAvailable }
    var localTranscriptionStatus: String { AppLocalTranscription.statusText }

    private var catalog: Catalog?
    private var bookmarkDataByPath: [String: Data] = [:]
    private var liveCoordinator: LiveIndexCoordinator?
    private var liveAccessLeases: [String: SecurityScopedBookmarkLease] = [:]
    private var activeIndexCancellation: IndexCancellationToken?

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PrivateLibrarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        self.localTranscriptionEnabled = UserDefaults.standard.bool(forKey: AppLocalTranscription.enabledDefaultsKey)
            && AppLocalTranscription.isAvailable
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
            restartLiveCoordinator()
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
                guard let data = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil), !data.isEmpty else {
                    self.log("could not persist read-only bookmark: \(url.path)")
                    continue
                }
                self.bookmarkDataByPath[url.path] = data
                if !self.sources.contains(where: { $0.path == url.path }) {
                    self.sources.append(SourceFolder(id: UUID(), path: url.path))
                }
                try? self.catalog?.restoreRootScope(root: url.path)
            }
            self.saveBookmarks()
            self.restartLiveCoordinator()
        }
    }

    func isPaused(_ source: SourceFolder) -> Bool { pausedPaths.contains(source.path) }

    func togglePaused(_ source: SourceFolder) {
        let isPausing: Bool
        if pausedPaths.contains(source.path) {
            pausedPaths.remove(source.path)
            isPausing = false
        } else {
            pausedPaths.insert(source.path)
            isPausing = true
        }
        if isPausing, isIndexing {
            activeIndexCancellation?.cancel()
            log("stopping current cleanup after this file…")
        }
        savePausedPaths()
        restartLiveCoordinator()
        refreshDashboard()
    }

    func removeSource(_ source: SourceFolder) {
        if isIndexing { activeIndexCancellation?.cancel() }
        try? catalog?.markRootUnscoped(root: source.path)
        sources.removeAll { $0.id == source.id }
        bookmarkDataByPath.removeValue(forKey: source.path)
        pausedPaths.remove(source.path)
        sourcesNeedingReauthorization.remove(source.path)
        saveBookmarks()
        savePausedPaths()
        restartLiveCoordinator()
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
            guard let data = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil), !data.isEmpty else {
                self.log("could not persist replacement bookmark: \(url.path)")
                return
            }
            if url.path != source.path {
                try? self.catalog?.markRootUnscoped(root: source.path)
            }
            self.bookmarkDataByPath.removeValue(forKey: source.path)
            self.bookmarkDataByPath[url.path] = data
            self.sourcesNeedingReauthorization.remove(source.path)
            self.sourcesNeedingReauthorization.remove(url.path)
            try? self.catalog?.restoreRootScope(root: url.path)
            if let index = self.sources.firstIndex(where: { $0.id == source.id }) {
                self.sources[index] = SourceFolder(id: source.id, path: url.path)
            }
            if self.pausedPaths.remove(source.path) != nil {
                self.pausedPaths.insert(url.path)
            }
            self.saveBookmarks()
            self.savePausedPaths()
            self.restartLiveCoordinator()
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
            self.restartLiveCoordinator()
            self.refreshDashboard()
        }
    }

    func removeExclusion(_ path: String) {
        excludedPaths.removeAll { $0 == path }
        saveExclusions()
        restartLiveCoordinator()
        refreshDashboard()
    }

    func needsReauthorization(_ source: SourceFolder) -> Bool {
        sourcesNeedingReauthorization.contains(source.path)
    }

    /// Resolve a stored read-only security-scoped bookmark and run `body`
    /// while access is active. Production app access never falls back to a raw
    /// path: missing, stale, and corrupt bookmarks require reauthorization.
    func withSource<T>(_ source: SourceFolder, _ body: (URL) throws -> T) rethrows -> T? {
        guard let lease = sourceLease(for: source) else { return nil }
        return try body(lease.url)
    }

    private func sourceLease(for source: SourceFolder) -> SecurityScopedBookmarkLease? {
        do {
            let lease = try SecurityScopedBookmarkLease(bookmarkData: bookmarkDataByPath[source.path])
            sourcesNeedingReauthorization.remove(source.path)
            return lease
        } catch {
            sourcesNeedingReauthorization.insert(source.path)
            log("folder needs reauthorization: \(source.path)")
            return nil
        }
    }

    private var effectiveExcludedPaths: [String] {
        let defaults = OnboardingExclusions.defaultPaths(
            catalogPath: Self.appSupportDir.appendingPathComponent("catalog.db").path,
            modelPaths: LocalModelBridge.modelsRoots().map(\.path))
        return Array(Set(defaults + excludedPaths)).sorted()
    }

    private func makeIndexer() -> Indexer? {
        guard let catalog else { return nil }
        var options = Indexer.Options()
        options.enableLocalEmbeddings = localEmbeddingsEnabled
        options.embeddingProviderKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        options.excludedPaths = effectiveExcludedPaths

        let transcriptionProvider: any SpeechTranscriptionProvider
        if localTranscriptionEnabled, let provider = AppLocalTranscription.providerIfAvailable() {
            options.enableLocalASR = true
            transcriptionProvider = provider
        } else {
            options.enableLocalASR = false
            transcriptionProvider = DisabledSpeechTranscriptionProvider()
        }

        return Indexer(broker: SourceBroker(), catalog: catalog,
                       scheduler: Scheduler(), options: options,
                       transcriptionProvider: transcriptionProvider)
    }

    private func restartLiveCoordinator() {
        liveCoordinator?.stop()
        liveCoordinator = nil
        // Dropping the leases balances every successful startAccessing call.
        liveAccessLeases.removeAll()
        liveIndexRunning = false
        livePendingEvents = 0
        guard let catalog, !sources.isEmpty else { return }

        var roots: [URL] = []
        var leases: [String: SecurityScopedBookmarkLease] = [:]
        for source in sources where !pausedPaths.contains(source.path) {
            guard let lease = sourceLease(for: source) else { continue }
            roots.append(lease.url)
            leases[source.path] = lease
        }
        guard !roots.isEmpty else { return }
        liveAccessLeases = leases

        var options = LiveIndexCoordinator.Options()
        options.excludedPaths = effectiveExcludedPaths
        let broker = SourceBroker()
        guard let indexer = makeIndexer() else {
            liveAccessLeases.removeAll()
            return
        }
        let coordinator = LiveIndexCoordinator(catalog: catalog, indexer: indexer,
                                               broker: broker, scheduler: Scheduler(),
                                               roots: roots, options: options)
        coordinator.onStateChange = { [weak self, weak coordinator] in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self else { return }
                self.livePendingEvents = coordinator?.pendingCount ?? 0
                self.refreshDashboard()
            }
        }
        liveCoordinator = coordinator
        coordinator.start()
        liveIndexRunning = coordinator.running
    }

    func cancelIndexing() {
        guard isIndexing else { return }
        activeIndexCancellation?.cancel()
        log("stopping cleanup after the current file…")
    }

    func startIndexing() {
        guard let indexer = makeIndexer(), let catalog, !isIndexing else { return }
        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources
            .filter { !pausedPaths.contains($0.path) }
            .compactMap { source in sourceLease(for: source).map { (source, $0) } }
        guard !jobs.isEmpty else {
            log("no authorized source folders available for cleanup")
            return
        }

        var sessionOptions = ScalableIndexSession.Options()
        sessionOptions.excludedPaths = effectiveExcludedPaths
        sessionOptions.excludedDirectoryNames = OnboardingExclusions.defaultDirectoryNames
        sessionOptions.enablePersistentEmbeddingWorker = localEmbeddingsEnabled
        sessionOptions.respectAccessBackoff = false // explicit user cleanup retries permission state
        let session = ScalableIndexSession(
            broker: SourceBroker(), catalog: catalog, indexer: indexer, options: sessionOptions)
        let token = IndexCancellationToken()
        activeIndexCancellation = token
        isIndexing = true
        log("cleanup started")

        Task.detached(priority: .userInitiated) { [weak self, jobs, session, token] in
            for (_, lease) in jobs {
                if token.isCancelled { break }
                _ = try? session.indexRoot(lease.url, cancellation: token) { progress in
                    Task { @MainActor [weak self] in
                        self?.log("cleanup… \(progress.scanned) files scanned")
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeIndexCancellation = nil
                self.isIndexing = false
                self.log(token.isCancelled ? "cleanup stopped" : "cleanup complete")
                self.refreshDashboard()
            }
        }
    }

    func refreshDashboard() {
        guard let catalog else { return }
        do {
            // The dashboard only needs aggregate graph counts. Do not load the
            // full organization graph or every similarity family onto the main
            // actor just to refresh counters on a huge catalog.
            dashboard = try catalog.dashboard()
            reviewItems = try catalog.reviewItems(limit: 200)
            learnedRules = try catalog.listRules()
            similarityClusters = try catalog.boundedSimilarityClusters(limit: 200)
            smartGroups = try catalog.smartOrganizationGroups()
            coverage = try catalog.coverage(roots: sources.map(\.path),
                                            excludedPaths: effectiveExcludedPaths)
            liveIndexRunning = liveCoordinator?.running ?? false
            livePendingEvents = liveCoordinator?.pendingCount ?? 0
        } catch {
            log("dashboard refresh error: \(error)")
        }
    }

    func files(for section: LibrarySection) -> [Catalog.FileSummary] {
        guard let catalog else { return [] }
        switch section {
        case .screenshots:
            let plural = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshots", limit: 200)) ?? []
            let singular = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshot", limit: 200)) ?? []
            return Array(Dictionary(uniqueKeysWithValues: (plural + singular).map { ($0.id, $0) })
                .values.sorted { $0.path < $1.path }.prefix(200))
        case .school:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "School", limit: 200)) ?? []
        case .projects:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "Projects", limit: 200)) ?? []
        case .documents:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "Documents", limit: 200)) ?? []
        case .media:
            return (try? catalog.boundedFileSummaries(kinds: [.audio, .video], limit: 200)) ?? []
        case .duplicates:
            return (try? catalog.boundedFileSummaries(duplicateOnly: true, limit: 200)) ?? []
        case .missing:
            return (try? catalog.boundedFileSummaries(status: "missing", limit: 200)) ?? []
        default:
            return (try? catalog.boundedFileSummaries(limit: 200)) ?? []
        }
    }

    func filePath(for id: String) -> String {
        guard let catalog else { return id }
        do {
            return try catalog.fileRow(id: id)?.path ?? id
        } catch {
            return id
        }
    }

    func previewRequest(for id: String) -> PreviewRequest? {
        guard let catalog,
              let row = try? catalog.fileRow(id: id),
              let source = sources
                .filter({ SourceBroker.isPath(row.path, under: $0.path) })
                .max(by: { $0.path.count < $1.path.count }) else { return nil }
        return PreviewRequest(path: row.path, sourceRoot: source.path,
                              bookmarkData: bookmarkDataByPath[source.path])
    }

    /// Load a bounded, read-only image snapshot for the similarity UI. This is
    /// intentionally nonisolated so the caller can perform the broker read
    /// away from the main actor; the source path is never passed to a model.
    nonisolated static func previewData(_ request: PreviewRequest) -> Data? {
        guard let lease = try? SecurityScopedBookmarkLease(bookmarkData: request.bookmarkData),
              let target = lease.targetURL(for: request.path, originalRootPath: request.sourceRoot) else {
            return nil
        }
        return try? SourceBroker().completeSnapshot(
            target.path, maxBytes: 16 * 1024 * 1024)
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

    func toggleLearnedRule(_ rule: LearnedRule) {
        guard let catalog else { return }
        do {
            try catalog.setRuleEnabled(id: rule.id, enabled: !rule.enabled)
            learnedRules = try catalog.listRules()
            refreshDashboard()
            startIndexing()
        } catch {
            log("learned rule update error: \(error)")
        }
    }

    func deleteLearnedRule(_ rule: LearnedRule) {
        guard let catalog else { return }
        do {
            try catalog.deleteRule(id: rule.id)
            learnedRules = try catalog.listRules()
            refreshDashboard()
            startIndexing()
        } catch {
            log("learned rule delete error: \(error)")
        }
    }

    func runSearch() {
        guard let catalog, !query.isEmpty else { return }
        let svc = SearchService(catalog: catalog, enableLocalEmbeddings: localEmbeddingsEnabled)
        let mode = searchMode
        var lines: [String] = []
        switch mode {
        case "exact":
            lines = ((try? svc.search(query)) ?? []).map { h in
                let evidence = h.snippet.map { "\n  evidence: \($0.replacingOccurrences(of: "\n", with: " "))" } ?? ""
                return "\(h.fileID) — \((h.path as NSString).lastPathComponent)\(evidence)"
            }
        case "semantic":
            lines = ((try? svc.semanticSearch(query: query)) ?? []).map { h in
                "\(h.fileID) — \((h.path as NSString).lastPathComponent)\n  evidence: semantic similarity \(String(format:"%.2f", h.score))"
            }
        case "clipText":
            lines = ((try? svc.clipTextToImageSearch(query: query)) ?? []).map { h in
                "\(h.fileID) — \((h.path as NSString).lastPathComponent)\n  evidence: CLIP text→image similarity \(String(format:"%.2f", h.score))"
            }
        default:
            let sem = (try? svc.semanticSearch(query: query)) ?? []
            if !sem.isEmpty {
                lines = sem.map { h in
                    "\(h.fileID) — \((h.path as NSString).lastPathComponent)\n  evidence: semantic similarity \(String(format:"%.2f", h.score))"
                }
            } else {
                let clip = (try? svc.clipTextToImageSearch(query: query)) ?? []
                if !clip.isEmpty {
                    lines = clip.map { h in
                        "\(h.fileID) — \((h.path as NSString).lastPathComponent)\n  evidence: CLIP text→image similarity \(String(format:"%.2f", h.score))"
                    }
                } else {
                    lines = ((try? svc.search(query)) ?? []).map { h in
                        let evidence = h.snippet.map { "\n  evidence: \($0.replacingOccurrences(of: "\n", with: " "))" } ?? ""
                        return "\(h.fileID) — \((h.path as NSString).lastPathComponent)\(evidence)"
                    }
                }
            }
        }
        if lines.isEmpty { lines = ["No results"] }
        searchResults = lines
    }

    /// Privacy indicators derived from ACTUAL state where possible (plan §45).
    func privacyIndicators() -> [(String, Bool)] {
        let sandboxed = amISandboxed()
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
        return catalog != nil && FileManager.default.fileExists(atPath: p)
            && !Catalog.onDiskHeaderIsPlaintextSQLite(path: p)
    }

    private func log(_ s: String) {
        statusLines.append(s)
        if statusLines.count > 200 { statusLines.removeFirst(statusLines.count - 200) }
    }

    // MARK: - Bookmark persistence

    private func saveBookmarks() {
        // Keep one entry per source. Compacting missing bookmarks would shift
        // every later bookmark onto the wrong root after a restart.
        let payload = sources.map { bookmarkDataByPath[$0.path]?.base64EncodedString() ?? "" }
        UserDefaults.standard.set(payload, forKey: "source-bookmarks-v1")
        UserDefaults.standard.set(sources.map(\.path), forKey: "source-paths-v1")
    }

    private func loadBookmarks() {
        guard let b64 = UserDefaults.standard.stringArray(forKey: "source-bookmarks-v1"),
              let paths = UserDefaults.standard.stringArray(forKey: "source-paths-v1") else { return }
        let aligned = b64.count == paths.count
        for (i, path) in paths.enumerated() {
            sources.append(SourceFolder(id: UUID(), path: path))
            if aligned, let data = Data(base64Encoded: b64[i]), !data.isEmpty {
                bookmarkDataByPath[path] = data
            }
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
