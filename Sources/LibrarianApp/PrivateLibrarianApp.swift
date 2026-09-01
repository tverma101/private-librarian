import SwiftUI
import AppKit
import LibrarianCore
import LibrarianAppSupport

/// Native SwiftUI shell (plan §1, §45, §46). No web server, no WebView,
/// no listening socket. Sources are added via the system folder picker with
/// read-only security-scoped bookmarks; the catalog is SQLCipher-encrypted
/// with its key in the app-owned Keychain.
@main
struct PrivateLibrarianApp: App {
    @NSApplicationDelegateAdaptor(PrivateLibrarianAppDelegate.self) private var appDelegate
    @StateObject private var model = LibrarianModel()

    var body: some Scene {
        WindowGroup("Private Librarian", id: "main") {
            CleanerHomeView()
                .environmentObject(model)
                .frame(minWidth: 720, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification)) { _ in
                    model.shutdown()
                }
        }
        .defaultSize(width: 820, height: 760)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Add Source Folder…") { model.addSourceFolder() }
                    .keyboardShortcut("o")
            }
        }
        // A `Window` (not WindowGroup) presents exactly one instance: repeated
        // openWindow(id:) calls focus the existing library instead of stacking
        // duplicate windows every time the user taps Library/Review/Duplicates.
        Window("Advanced Library", id: "advanced-library") {
            MagicContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1100, height: 720)

        Settings {
            SimpleSettingsView()
                .environmentObject(model)
        }
    }
}

/// Keep the app a normal, activatable Dock application. SwiftUI's state
/// restoration can restore the scene controller before a window is visible;
/// explicitly activating the regular app lets the primary WindowGroup present
/// instead of leaving a live process with no user-facing window.
final class PrivateLibrarianAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
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

    private struct Tier2Readiness: Sendable {
        let coreML: Bool
        let legacyClip: Bool
        let legacyMiniLM: Bool
        let legacyRuntime: Bool
        let specialistIDs: Set<String>
        let specialistRuntimeIDs: Set<String>
    }

    /// What the last "Clean Up" actually did, per folder, so the home screen
    /// can answer "what just got sorted?" instead of only "cleanup complete".
    struct CleanupFolderReport: Identifiable, Sendable, Equatable {
        let rootPath: String
        let scanned: Int
        let processed: Int
        let missingMarked: Int
        let unreadableDirectories: Int
        let completion: String

        var id: String { rootPath }
        var displayName: String {
            (rootPath as NSString).lastPathComponent.isEmpty ? rootPath : (rootPath as NSString).lastPathComponent
        }
    }

    struct CleanupReport: Sendable, Equatable {
        let finishedAt: Date
        let folders: [CleanupFolderReport]
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
    @Published var projectSummaries: [ProjectSemanticSummary] = []
    @Published private(set) var sectionFiles: [Catalog.FileSummary] = []
    @Published private(set) var lastCleanupReport: CleanupReport?
    @Published private(set) var changedGroupIDs: Set<String> = []
    @Published var pendingApplyPlan: OrganizationApplier.Plan?
    @Published private(set) var lastApplyMessage: String?
    @Published private(set) var canUndoApply = false
    @Published private(set) var pausedPaths: Set<String> = []
    @Published private(set) var liveIndexRunning = false
    @Published private(set) var livePendingEvents = 0
    @Published private(set) var sourcesNeedingReauthorization: Set<String> = []
    @Published private(set) var catalogMigrationRequired = false
    @Published private(set) var catalogMigrationAttempted = false
    @Published private(set) var catalogReady = false
    @Published private(set) var catalogError: String?
    @Published private(set) var isTier2Provisioned = false
    @Published private(set) var specialistProvisionedIDs: Set<String> = []
    @Published private(set) var tier2Status = "Checking local model readiness…"
    @Published private(set) var isSearching = false
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
    @Published var localModelProfile: LocalModelProfile {
        didSet {
            UserDefaults.standard.set(localModelProfile.rawValue, forKey: "local-model-profile-v1")
            restartLiveCoordinator()
            refreshDashboard()
        }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText

    var isLocalTranscriptionAvailable: Bool { AppLocalTranscription.isAvailable }
    var localTranscriptionStatus: String { AppLocalTranscription.statusText }
    var isUsingFreshCatalog: Bool { activeCatalogFilename == Self.freshCatalogFilename }

    private var catalog: Catalog?
    private var bookmarkDataByPath: [String: Data] = [:]
    private var liveCoordinator: LiveIndexCoordinator?
    private var liveAccessLeases: [String: SecurityScopedBookmarkLease] = [:]
    private var activeIndexCancellation: IndexCancellationToken?
    private var hasStarted = false
    private var modelStatusTask: Task<Void, Never>?
    private var modelStatusGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = 0

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PrivateLibrarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let catalogFilename = "catalog.db"
    private static let freshCatalogFilename = "catalog-fresh.db"
    private static let activeCatalogFilenameKey = "catalog-active-filename-v1"

    private var activeCatalogFilename: String {
        UserDefaults.standard.string(forKey: Self.activeCatalogFilenameKey) == Self.freshCatalogFilename
            ? Self.freshCatalogFilename
            : Self.catalogFilename
    }

    private var catalogURL: URL {
        Self.appSupportDir.appendingPathComponent(activeCatalogFilename)
    }

    private var legacyCatalogURL: URL {
        Self.appSupportDir.appendingPathComponent(Self.catalogFilename)
    }

    init() {
        self.localTranscriptionEnabled = UserDefaults.standard.bool(forKey: AppLocalTranscription.enabledDefaultsKey)
            && AppLocalTranscription.isAvailable
        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        self.localModelProfile = LocalModelProfile(
            rawValue: UserDefaults.standard.string(forKey: "local-model-profile-v1") ?? "fast") ?? .fast
        if let m = UserDefaults.standard.string(forKey: "tier2-search-mode-v1") { self.searchMode = m }
        loadBookmarks()
        loadExclusions()
        loadPausedPaths()
        refreshModelStatus()
    }

    // MARK: - Catalog

    /// Start after the first window has appeared. Legacy Keychain migration
    /// can require user approval; doing it from init would block SwiftUI from
    /// rendering any window or status explaining what is happening.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        refreshModelStatus()
        openCatalogIfNeeded()
        refreshDashboard()
    }

    /// Readiness checks can enumerate large model snapshots and invoke a small
    /// dependency probe. Keep that work off the main actor and cache the result
    /// until the user explicitly refreshes it or changes the model setup.
    func refreshModelStatus() {
        modelStatusTask?.cancel()
        modelStatusGeneration += 1
        let generation = modelStatusGeneration
        tier2Status = "Checking local model readiness…"
        let work = Task.detached(priority: .utility) {
            let legacyClip = LocalModelBridge.isProvisioned(.clipImage)
            let legacyMiniLM = LocalModelBridge.isProvisioned(.miniLMText)
            let specialistIDs = SpecialistModelBridge.availableModelIDs()
            let specialistRuntimeIDs = Set<String>(specialistIDs.compactMap { (id: String) -> String? in
                guard let descriptor = LocalModelStack.all.first(where: { $0.id == id }) else { return nil }
                return SpecialistModelBridge.preflight(descriptor).available ? id : nil
            })
            return Tier2Readiness(
                coreML: CoreMLMobileCLIPProvider.isAvailable,
                legacyClip: legacyClip,
                legacyMiniLM: legacyMiniLM,
                legacyRuntime: (legacyClip || legacyMiniLM) && LocalModelBridge.isAvailable(),
                specialistIDs: specialistIDs,
                specialistRuntimeIDs: specialistRuntimeIDs)
        }
        modelStatusTask = Task { @MainActor [weak self] in
            let readiness = await work.value
            guard let self, self.modelStatusGeneration == generation else { return }
            self.specialistProvisionedIDs = readiness.specialistIDs
            self.isTier2Provisioned = readiness.coreML
                || readiness.legacyRuntime
                || !readiness.specialistRuntimeIDs.isEmpty
            if readiness.specialistRuntimeIDs.contains(LocalModelStack.siglip2.id) {
                self.tier2Status = "Tier-2 ready — local SigLIP2 specialist"
            } else if readiness.coreML {
                self.tier2Status = "Tier-2 ready — Core ML MobileCLIP"
            } else if readiness.legacyRuntime {
                self.tier2Status = "Tier-2 ready — offline Python embeddings"
            } else if readiness.legacyClip || readiness.legacyMiniLM {
                self.tier2Status = "Checkpoint files found; offline Python runtime is unavailable"
            } else if !readiness.specialistIDs.isEmpty {
                self.tier2Status = "Specialist checkpoints found; their offline runtime is unavailable"
            } else {
                self.tier2Status = "Tier-2 not provisioned — run scripts/setup_models.sh"
            }
        }
    }

    private func openCatalogIfNeeded() {
        guard catalog == nil else { return }
        do {
            if let key = try CatalogKeychain.load() {
                try openCatalog(key: key, at: catalogURL)
            } else {
                let dbExists = FileManager.default.fileExists(atPath: catalogURL.path)
                if activeCatalogFilename == Self.freshCatalogFilename {
                    if dbExists {
                        catalogError = "the fresh catalog key is unavailable; its encrypted data was left untouched"
                        log("fresh catalog key is unavailable; encrypted catalog was left untouched")
                    } else {
                        try openCatalog(key: CatalogKeychain.createAppOwned(), at: catalogURL)
                    }
                } else if dbExists {
                    catalogMigrationRequired = true
                    catalogReady = false
                    log("existing catalog needs one-time Keychain migration · choose Migrate Existing Catalog")
                } else {
                    try openCatalog(key: CatalogKeychain.createAppOwned(), at: catalogURL)
                }
            }
        } catch {
            catalogReady = false
            catalogError = error.localizedDescription
            log("catalog error: \(error)")
        }
    }

    private func openCatalog(key: Data, at url: URL) throws {
        catalog = try Catalog(path: url.path, key: key)
        catalogMigrationRequired = false
        catalogError = nil
        catalogReady = true
        if url.lastPathComponent == Self.freshCatalogFilename {
            log("new catalog opened (encrypted); existing catalog.db remains untouched")
        } else {
            log("catalog opened (encrypted)")
        }
        restartLiveCoordinator()
    }

    /// Perform the only legacy Keychain read, after the user has explicitly
    /// requested migration from the visible settings control.
    func migrateCatalog() {
        guard catalog == nil, catalogMigrationRequired, !catalogMigrationAttempted else { return }
        catalogMigrationAttempted = true
        do {
            guard let key = try CatalogKeychain.migrateLegacy() else {
                log("legacy catalog key was not found; existing encrypted catalog was left untouched")
                return
            }
            try openCatalog(key: key, at: legacyCatalogURL)
            refreshDashboard()
        } catch {
            log("catalog migration error: \(error)")
        }
    }

    /// Open a new encrypted catalog without touching an existing catalog whose
    /// key lives in the legacy login Keychain. The old database and sidecars
    /// stay in place so this choice is recoverable and does not require a
    /// Keychain approval. The existing catalog remains available for a later
    /// explicit recovery/migration workflow.
    func startFreshCatalog() {
        guard catalog == nil,
              catalogMigrationRequired,
              !catalogMigrationAttempted,
              activeCatalogFilename == Self.catalogFilename else { return }

        let freshURL = Self.appSupportDir.appendingPathComponent(Self.freshCatalogFilename)
        guard !FileManager.default.fileExists(atPath: freshURL.path) else {
            catalogError = "a fresh catalog already exists, but its app-owned key is unavailable"
            log("fresh catalog already exists; existing catalog.db was left untouched")
            return
        }

        do {
            let key = try CatalogKeychain.createAppOwned()
            UserDefaults.standard.set(Self.freshCatalogFilename, forKey: Self.activeCatalogFilenameKey)
            try openCatalog(key: key, at: freshURL)
            refreshDashboard()
        } catch {
            UserDefaults.standard.removeObject(forKey: Self.activeCatalogFilenameKey)
            catalogReady = false
            catalogError = error.localizedDescription
            log("could not start fresh catalog: \(error); existing catalog.db was left untouched")
        }
    }

    func retryCatalogOpen() {
        guard catalog == nil, !catalogMigrationRequired else { return }
        catalogError = nil
        openCatalogIfNeeded()
        refreshDashboard()
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
            activeIndexCancellation?.cancel(reason: .paused)
            log("stopping current cleanup after this file…")
        }
        savePausedPaths()
        restartLiveCoordinator()
        refreshDashboard()
    }

    func removeSource(_ source: SourceFolder) {
        if isIndexing { activeIndexCancellation?.cancel(reason: .removed) }
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
            catalogPath: catalogURL.path,
            modelPaths: LocalModelBridge.modelsRoots().map(\.path))
        return Array(Set(defaults + [legacyCatalogURL.path] + excludedPaths)).sorted()
    }

    private func makeIndexer() -> Indexer? {
        guard let catalog else { return nil }
        var options = Indexer.Options()
        options.enableLocalEmbeddings = localEmbeddingsEnabled
        options.embeddingProviderKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        options.localModelProfile = localModelProfile
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

    private func stopLiveCoordinator() {
        liveCoordinator?.stop()
        liveCoordinator = nil
        // Dropping the leases balances every successful startAccessing call.
        liveAccessLeases.removeAll()
        liveIndexRunning = false
        livePendingEvents = 0
    }

    private func restartLiveCoordinator() {
        stopLiveCoordinator()
        // A manual cleanup owns the catalog/session window. Do not let a live
        // FSEvent or wake reconciliation overlap the same root; completion of
        // the cleanup calls this method again to restore live indexing.
        guard !isIndexing else { return }
        guard let catalog, !sources.isEmpty else { return }

        var roots: [URL] = []
        var leases: [String: SecurityScopedBookmarkLease] = [:]
        for source in sources
            where !pausedPaths.contains(source.path)
                && !sourcesNeedingReauthorization.contains(source.path) {
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
        coordinator.onRootAccessLost = { [weak self, weak coordinator] resolvedPath, reason in
            Task { @MainActor [weak self, weak coordinator] in
                guard let self, coordinator != nil else { return }
                let source = self.sources.first { candidate in
                    candidate.path == resolvedPath
                        || self.liveAccessLeases[candidate.path]?.url.path == resolvedPath
                }
                guard let source else { return }
                self.sourcesNeedingReauthorization.insert(source.path)
                self.log("folder needs reauthorization: \(source.path) · \(reason)")
                self.restartLiveCoordinator()
                self.refreshDashboard()
            }
        }
        liveCoordinator = coordinator
        coordinator.start()
        liveIndexRunning = coordinator.running
    }

    func cancelIndexing() {
        guard isIndexing else { return }
        activeIndexCancellation?.cancel(reason: .cancelled)
        log("stopping cleanup after the current file…")
    }

    // MARK: - Apply to Finder (explicit, journaled, undoable)

    /// Build the preview plan for turning one virtual group into a real
    /// folder. Nothing moves until `confirmApply()` runs.
    func prepareApply(group: SmartOrganizationGroup) {
        guard catalogReady, let catalog else { return }
        let roots = sources.map(\.path)
        Task.detached(priority: .userInitiated) { [weak self, catalog, group, roots] in
            do {
                let plan = try OrganizationApplier.plan(
                    group: group,
                    pathFor: { fileID in (try? catalog.fileRow(id: fileID))?.path ?? "" },
                    sourceRoots: roots)
                await MainActor.run { [weak self] in
                    self?.pendingApplyPlan = plan
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("could not prepare apply: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelApply() {
        pendingApplyPlan = nil
    }

    /// Execute the confirmed plan with fresh security-scoped leases, then
    /// refresh the dashboard so the group reflects the new locations.
    func confirmApply() {
        guard let plan = pendingApplyPlan else { return }
        pendingApplyPlan = nil
        guard catalogReady, let catalog else { return }
        let bookmarkData = bookmarkDataByPath
        let roots = sources.map(\.path)
        log("applying \"\(plan.groupTitle)\" · moving \(plan.items.count) files…")
        Task.detached(priority: .userInitiated) { [weak self, catalog, plan, bookmarkData, roots] in
            do {
                let outcome = try OrganizationApplier.apply(
                    plan: plan,
                    leaseForRoot: { rootPath in
                        try SecurityScopedBookmarkLease(bookmarkData: bookmarkData[rootPath])
                    },
                    catalog: catalog)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.lastApplyMessage = outcome.succeeded
                        ? "Moved \(outcome.moved) files to \(outcome.destinationFolderPath)"
                        : "Moved \(outcome.moved) of \(outcome.moved + outcome.failures.count) files · \(outcome.failures.count) failed"
                    if !outcome.failures.isEmpty {
                        self.log("apply failures: \(outcome.failures.prefix(5).map { "\($0.path): \($0.reason)" }.joined(separator: " · "))")
                    }
                    self.log("applied \"\(plan.groupTitle)\" · \(outcome.destinationFolderPath)")
                    self.refreshDashboard()
                    self.updateUndoAvailability()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("apply failed: \(error.localizedDescription)")
                    self?.lastApplyMessage = "Apply failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func undoLastApply() {
        guard catalogReady, let catalog else { return }
        let bookmarkData = bookmarkDataByPath
        let roots = sources.map(\.path)
        Task.detached(priority: .userInitiated) { [weak self, catalog, bookmarkData, roots] in
            let outcome = OrganizationApplier.undoLatest(
                catalog: catalog,
                sourceRoots: roots,
                leaseForRoot: { rootPath in
                    try SecurityScopedBookmarkLease(bookmarkData: bookmarkData[rootPath])
                })
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let outcome {
                    self.lastApplyMessage = outcome.succeeded
                        ? "Undo complete · \(outcome.restored) files restored"
                        : "Undo restored \(outcome.restored) files · \(outcome.failures.count) failed"
                    self.log(self.lastApplyMessage ?? "")
                } else {
                    self.lastApplyMessage = "Nothing left to undo"
                }
                self.refreshDashboard()
                self.updateUndoAvailability()
            }
        }
    }

    private func updateUndoAvailability() {
        guard let catalog else {
            canUndoApply = false
            return
        }
        canUndoApply = ((try? catalog.latestApplyBatchID()) ?? nil) != nil
    }

    func shutdown() {
        activeIndexCancellation?.cancel(reason: .shutdown)
        modelStatusTask?.cancel()
        searchTask?.cancel()
        stopLiveCoordinator()
    }

    func startIndexing() {
        if isIndexing {
            activeIndexCancellation?.cancel(reason: .replaced)
            log("replacement cleanup requested; stopping after the current file…")
            return
        }
        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources
            .filter {
                !pausedPaths.contains($0.path)
                    && !sourcesNeedingReauthorization.contains($0.path)
            }
            .compactMap { source in sourceLease(for: source).map { (source, $0) } }
        startCleanup(jobs: jobs, scopeLabel: "all authorized folders")
    }

    func startIndexing(source: SourceFolder) {
        if isIndexing {
            activeIndexCancellation?.cancel(reason: .replaced)
            log("replacement cleanup requested; stopping after the current file…")
            return
        }
        guard !pausedPaths.contains(source.path) else { return }
        guard let lease = sourceLease(for: source) else {
            log("folder needs reauthorization before cleanup: \(source.path)")
            return
        }
        let name = (source.path as NSString).lastPathComponent
        startCleanup(jobs: [(source, lease)],
                     scopeLabel: name.isEmpty ? source.path : name)
    }

    private func startCleanup(
        jobs: [(SourceFolder, SecurityScopedBookmarkLease)],
        scopeLabel: String
    ) {
        guard let indexer = makeIndexer(), let catalog, !isIndexing else { return }
        guard !jobs.isEmpty else {
            log("no authorized source folders available for cleanup")
            return
        }

        stopLiveCoordinator()

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
        // Snapshot group sizes so completion can show exactly which groups the
        // cleanup created or grew ("what did it just organize?").
        let groupSizesBefore = Dictionary(uniqueKeysWithValues: smartGroups.map { ($0.id, $0.fileIDs.count) })
        log("cleanup started · \(scopeLabel)")

        Task.detached(priority: .userInitiated) { [weak self, jobs, session, token, scopeLabel, groupSizesBefore] in
            var unavailableSources: [String] = []
            var completionReasons: [String] = []
            var folderReports: [CleanupFolderReport] = []
            for (source, lease) in jobs {
                if token.isCancelled { break }
                do {
                    let result = try session.indexRoot(lease.url, cancellation: token) { progress in
                        Task { @MainActor [weak self] in
                            self?.log("cleanup \(scopeLabel) · \(progress.rootPath)… \(progress.scanned) files scanned")
                        }
                    }
                    completionReasons.append("\(source.path)=\(result.completion.rawValue)")
                    folderReports.append(CleanupFolderReport(
                        rootPath: source.path,
                        scanned: result.scanned,
                        processed: result.processed,
                        missingMarked: result.missingMarked,
                        unreadableDirectories: result.unreadableDirectories,
                        completion: result.completion.rawValue))
                    if result.completion == .rootUnavailable {
                        unavailableSources.append(source.path)
                    }
                } catch {
                    Task { @MainActor [weak self] in
                        self?.log("cleanup \(scopeLabel) failed for \(source.path): \(error)")
                    }
                }
            }
            let unavailableSnapshot = unavailableSources
            let completionSnapshot = completionReasons
            let reportSnapshot = folderReports
            await MainActor.run { [weak self] in
                guard let self else { return }
                for path in unavailableSnapshot {
                    self.sourcesNeedingReauthorization.insert(path)
                }
                self.activeIndexCancellation = nil
                self.isIndexing = false
                self.refreshDashboard()
                if !reportSnapshot.isEmpty {
                    self.lastCleanupReport = CleanupReport(finishedAt: Date(), folders: reportSnapshot)
                    let sizesAfter = Dictionary(uniqueKeysWithValues: self.smartGroups.map { ($0.id, $0.fileIDs.count) })
                    self.changedGroupIDs = Set(sizesAfter.filter { id, count in
                        (groupSizesBefore[id] ?? 0) < count
                    }.keys)
                }
                if token.isCancelled {
                    self.log("cleanup stopped · \(token.reason?.rawValue ?? "cancelled")")
                } else if completionSnapshot.contains(where: { $0.hasSuffix("=rootUnavailable") }) {
                    self.log("cleanup complete with unavailable folder · \(scopeLabel)")
                } else {
                    self.log("cleanup complete · \(scopeLabel)")
                }
                self.restartLiveCoordinator()
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
            projectSummaries = try catalog.projectSemanticSummaries(limit: 128)
            coverage = try catalog.coverage(roots: sources.map(\.path),
                                            excludedPaths: effectiveExcludedPaths)
            liveIndexRunning = liveCoordinator?.running ?? false
            livePendingEvents = liveCoordinator?.pendingCount ?? 0
        } catch {
            log("dashboard refresh error: \(error)")
        }
        reloadSectionFiles()
        updateUndoAvailability()
    }

    /// Section listings run bounded catalog queries; keep them off the main
    /// actor and only publish results for the still-selected section.
    func reloadSectionFiles() {
        let section = selectedSection
        guard let catalog else {
            sectionFiles = []
            return
        }
        Task.detached(priority: .userInitiated) { [weak self, catalog, section] in
            let files = Self.sectionFileSummaries(catalog: catalog, section: section)
            await MainActor.run { [weak self] in
                guard let self, self.selectedSection == section else { return }
                self.sectionFiles = files
            }
        }
    }

    private nonisolated static func sectionFileSummaries(
        catalog: Catalog, section: LibrarySection
    ) -> [Catalog.FileSummary] {
        switch section {
        case .screenshots:
            let plural = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshots", limit: 200)) ?? []
            let singular = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshot", limit: 200)) ?? []
            return Array(Dictionary((plural + singular).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        guard let catalog, !normalizedQuery.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        searchResults = []
        let enabled = localEmbeddingsEnabled
        let profile = localModelProfile
        let mode = searchMode
        let providerKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        let work = Task.detached(priority: .userInitiated) {
            Self.searchLines(catalog: catalog, query: normalizedQuery, mode: mode,
                             enableLocalEmbeddings: enabled, localModelProfile: profile,
                             embeddingProviderKind: providerKind)
        }
        searchTask = Task { @MainActor [weak self] in
            let lines = await work.value
            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
            self.searchResults = lines.isEmpty ? ["No results"] : lines
        }
    }

    private nonisolated static func searchLines(
        catalog: Catalog,
        query: String,
        mode: String,
        enableLocalEmbeddings: Bool,
        localModelProfile: LocalModelProfile,
        embeddingProviderKind: String?
    ) -> [String] {
        let service = SearchService(
            catalog: catalog,
            enableLocalEmbeddings: enableLocalEmbeddings,
            localModelProfile: localModelProfile,
            embeddingProviderKind: embeddingProviderKind)
        func exactLines() -> [String] {
            ((try? service.search(query)) ?? []).map { hit in
                let evidence = hit.snippet.map {
                    "\n  evidence: \($0.replacingOccurrences(of: "\n", with: " "))"
                } ?? ""
                return "\(hit.fileID) — \((hit.path as NSString).lastPathComponent)\(evidence)"
            }
        }
        func semanticLines() -> [String] {
            ((try? service.semanticSearch(query: query)) ?? []).map { hit in
                "\(hit.fileID) — \((hit.path as NSString).lastPathComponent)\n  evidence: semantic similarity \(String(format: "%.2f", hit.score))"
            }
        }
        func clipLines() -> [String] {
            ((try? service.clipTextToImageSearch(query: query)) ?? []).map { hit in
                "\(hit.fileID) — \((hit.path as NSString).lastPathComponent)\n  evidence: CLIP text→image similarity \(String(format: "%.2f", hit.score))"
            }
        }

        switch mode {
        case "exact": return exactLines()
        case "semantic": return semanticLines()
        case "clipText": return clipLines()
        default:
            let semantic = semanticLines()
            if !semantic.isEmpty { return semantic }
            let clip = clipLines()
            return clip.isEmpty ? exactLines() : clip
        }
    }

    /// Privacy indicators derived from ACTUAL state where possible (plan §45).
    func privacyIndicators() -> [(String, Bool)] {
        let sandboxed = amISandboxed()
        return [
            ("App Sandbox enabled", sandboxed),
            ("Read-only unless you apply a plan", true), // SourceBroker O_RDONLY|O_NOFOLLOW; moves only via journaled apply
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
        let p = catalogURL.path
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
