import SwiftUI
import AppKit
import LibrarianCore
import LibrarianAppSupport

/// Native SwiftUI shell (plan §1, §45, §46). No web server, no WebView,
/// no listening socket. Sources are added via the system folder picker with
/// security-scoped bookmarks; the catalog is SQLCipher-encrypted
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
        Window("Library", id: "advanced-library") {
            MagicContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 620)
                .background(LibraryWindowRestorationGuard())
        }
        .defaultSize(width: 1180, height: 760)
        // Library is an on-demand workspace, not a second launch surface.
        // Restoring it alongside Home made a normal relaunch look like a
        // duplicate app/window and obscured the single source of truth.

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

        // A pre-fix restoration archive can be decoded before SwiftUI has
        // attached the Library content guard. Give AppKit a short bounded
        // window to finish creating restored scenes, then remove only that
        // transient auxiliary window. Later user-opened Library windows are
        // left alone.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.removeRestoredLibraryWindows()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ app: NSApplication, didDecodeRestorableState coder: NSCoder) {
        // macOS 14 has no SwiftUI restorationBehavior modifier. If an older
        // build left an auxiliary Library window in the restoration archive,
        // remove that one stale surface after AppKit has decoded it. The
        // primary Home window remains untouched.
        DispatchQueue.main.async {
            let restoredLibraryWindows = app.windows.filter(Self.isLibraryWindow)
            for window in restoredLibraryWindows {
                Self.disableRestoration(for: window)
                window.close()
            }
            app.invalidateRestorableState()
        }
    }

    func application(_ app: NSApplication, willEncodeRestorableState coder: NSCoder) {
        // Prevent a Library window opened during this session from becoming
        // the next stale launch surface. Home may retain normal macOS frame
        // restoration; this only targets the transient workspace.
        for window in app.windows where Self.isLibraryWindow(window) {
            Self.disableRestoration(for: window)
        }
    }

    private func removeRestoredLibraryWindows() {
        let restoredLibraryWindows = NSApp.windows.filter(Self.isLibraryWindow)
        for window in restoredLibraryWindows {
            Self.disableRestoration(for: window)
            window.close()
        }
        NSApp.invalidateRestorableState()
    }

    fileprivate static func isLibraryWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue == "advanced-library" || window.title == "Library"
    }

    fileprivate static func disableRestoration(for window: NSWindow) {
        window.isRestorable = false
        window.restorationClass = nil
    }
}

/// AppKit bridge for the macOS 14 deployment target. SwiftUI's per-scene
/// `.restorationBehavior(.disabled)` is macOS 15+, so the transient Library
/// workspace opts out as soon as its NSWindow exists instead.
private struct LibraryWindowRestorationGuard: NSViewRepresentable {
    func makeNSView(context: Context) -> GuardView { GuardView() }

    func updateNSView(_ nsView: GuardView, context: Context) {}

    final class GuardView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            PrivateLibrarianAppDelegate.disableRestoration(for: window)
        }
    }
}

@MainActor
final class LibrarianModel: ObservableObject {

    struct SourceFolder: Identifiable, Codable, Sendable {
        let id: UUID
        let path: String
    }

    /// One search hit rendered by both surfaces. Carries the real path (the
    /// old string rows led with an opaque catalog file ID, which told the
    /// user nothing about where the file lives) plus the match context.
    struct SearchResult: Identifiable, Sendable, Equatable {
        let id: String
        let path: String
        let snippet: String
        let modeLabel: String
    }

    /// The last user-visible operation status, including when it happened.
    /// The history remains available for diagnostics, but surfaces should not
    /// make a bare, untimestamped status string look current forever.
    struct StatusEvent: Sendable, Equatable {
        let message: String
        let timestamp: Date

        var isWarning: Bool {
            let lowercased = message.lowercased()
            return lowercased.contains("error")
                || lowercased.contains("failed")
                || lowercased.contains("warning")
                || lowercased.contains("unavailable")
                || lowercased.contains("blocked")
                || lowercased.contains("could not")
        }
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

    /// What the last analysis run actually did, per folder, so the home screen
    /// can answer "what just happened to my folder?" instead of only
    /// "analysis complete".
    struct CleanupFolderReport: Identifiable, Sendable, Equatable {
        let rootPath: String
        let knownBefore: Int
        let scanned: Int
        let processed: Int
        let missingMarked: Int
        let unreadableDirectories: Int
        let completion: String

        var id: String { rootPath }
        var displayName: String {
            (rootPath as NSString).lastPathComponent.isEmpty ? rootPath : (rootPath as NSString).lastPathComponent
        }

        /// One honest line about this folder's run, including the explicit
        /// "nothing changed" case instead of a row of zeros.
        var detailLine: String {
            var parts: [String] = ["\(scanned) files checked"]
            if processed > 0 {
                parts.append("\(processed) analyzed (new or changed)")
            }
            if missingMarked > 0 {
                parts.append("\(missingMarked) no longer on disk")
            }
            if unreadableDirectories > 0 {
                parts.append("\(unreadableDirectories) folders unreadable")
            }
            if processed == 0 && missingMarked == 0 {
                parts.append(scanned == 0 ? "folder is empty" : "already analyzed, nothing changed")
            }
            return parts.joined(separator: " · ")
        }
    }

    struct CleanupReport: Sendable, Equatable {
        let finishedAt: Date
        let duration: TimeInterval
        let folders: [CleanupFolderReport]

        var totalScanned: Int { folders.reduce(0) { $0 + $1.scanned } }
        var totalProcessed: Int { folders.reduce(0) { $0 + $1.processed } }
        var totalMissing: Int { folders.reduce(0) { $0 + $1.missingMarked } }
        var ranCleanly: Bool { folders.allSatisfy { $0.completion == "completed" } }

        var headline: String {
            if !ranCleanly { return "Analysis finished with warnings" }
            return (totalProcessed > 0 || totalMissing > 0) ? "Analysis complete" : "Already up to date"
        }

        var summaryLine: String {
            var parts = ["\(totalScanned) files checked"]
            if totalProcessed > 0 {
                parts.append("\(totalProcessed) analyzed")
            } else {
                parts.append("nothing new")
            }
            if totalMissing > 0 {
                parts.append("\(totalMissing) missing")
            }
            parts.append("\(folders.count) folder" + (folders.count == 1 ? "" : "s"))
            return parts.joined(separator: " · ")
        }
    }

    @Published var sources: [SourceFolder] = []
    @Published var statusLines: [String] = []
    @Published private(set) var latestStatusEvent: StatusEvent?
    @Published var searchResults: [SearchResult] = []
    @Published var query: String = "" {
        didSet {
            // Old "No results" text must never describe a query that was
            // never submitted.
            if query != oldValue, searchFoundNothing { searchFoundNothing = false }
        }
    }
    @Published var isIndexing = false
    @Published var selectedSection: LibrarySection = .overview
    @Published var libraryScope: LibraryScope = .allAuthorized
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
    @Published private(set) var isApplyOperationInProgress = false
    @Published private(set) var isReconciling = false
    /// Bumped whenever a preview is superseded (applied, cancelled, or being
    /// replanned) so an in-flight replan cannot re-present a stale sheet.
    private var applyReplanGeneration = 0
    @Published private(set) var pausedPaths: Set<String> = []
    @Published private(set) var liveIndexRunning = false
    @Published private(set) var livePendingEvents = 0
    @Published private(set) var sourcesNeedingReauthorization: Set<String> = []
    @Published private(set) var catalogMigrationRequired = false
    @Published private(set) var catalogMigrationAttempted = false
    @Published private(set) var catalogReady = false
    @Published private(set) var catalogError: String?
    @Published private(set) var isTier2Provisioned = false
    @Published private(set) var specialistReadyIDs: Set<String> = []
    @Published private(set) var tier2Status = "Checking local model readiness…"
    @Published private(set) var isSearching = false
    @Published private(set) var searchFoundNothing = false
    /// True while an apply preview is being computed (first plan or a replan).
    /// The apply sheet and every Apply button disable on this so a stale plan
    /// can never execute for a destination the user just switched away from.
    @Published private(set) var isPreparingPlan = false
    /// Per-file failures from the last apply or undo. The status line only has
    /// room for "N failed" — these rows answer "which files, and why".
    struct ApplyFailureReport: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let failures: [OrganizationApplier.Outcome.Failure]
    }
    @Published private(set) var lastApplyFailureReport: ApplyFailureReport?
    /// Context for the Undo button: how many files the latest journal batch
    /// holds, so Undo after a restart isn't a blind action.
    @Published private(set) var undoBatchFileCount: Int = 0
    @Published var localTranscriptionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(localTranscriptionEnabled, forKey: AppLocalTranscription.enabledDefaultsKey)
            restartLiveCoordinator()
            refreshDashboard()
            // Enabling transcription changes how audio is processed, so a
            // re-analysis applies it. Disabling keeps the existing transcripts
            // valid — starting a multi-hour scan for no change would be churn.
            if localTranscriptionEnabled {
                startIndexing()
            }
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
            // Quality is the consumer-facing source of truth. Fast means the
            // zero-download path; Balanced/Quality mean their downloaded local
            // stack is actually enabled. Do not let an old hidden Tier-2 toggle
            // silently make the selected quality level lie to the user.
            let shouldEnable = localModelProfile != .fast
            if localEmbeddingsEnabled != shouldEnable {
                localEmbeddingsEnabled = shouldEnable
            } else {
                restartLiveCoordinator()
                refreshDashboard()
            }
        }
    }
    @Published var searchMode: String = "auto" // auto | exact | semantic | visual | clipText

    var isLocalTranscriptionAvailable: Bool { AppLocalTranscription.isAvailable }
    var localTranscriptionStatus: String { AppLocalTranscription.statusText }
    var isUsingFreshCatalog: Bool { activeCatalogFilename == Self.freshCatalogFilename }

    var libraryScopeSource: SourceFolder? {
        guard case .source(let id) = libraryScope else { return nil }
        return sources.first(where: { $0.id == id })
    }

    /// Roots passed into scoped catalog queries. `[]` is intentional when no
    /// source is authorized: the explicit aggregate view should not resurrect
    /// stale rows from a removed folder.
    var libraryScopeRoots: [String] {
        switch libraryScope {
        case .allAuthorized:
            return sources.map(\.path)
        case .source:
            return libraryScopeSource.map { [$0.path] } ?? []
        }
    }

    var libraryScopeLabel: String {
        if let source = libraryScopeSource {
            let name = (source.path as NSString).lastPathComponent
            return name.isEmpty ? source.path : name
        }
        return "All authorized folders"
    }

    var libraryScopeDescription: String {
        if let source = libraryScopeSource {
            return "Showing only catalog records under \(source.path)."
        }
        return sources.isEmpty
            ? "No authorized folders are currently included."
            : "Showing the combined catalog for \(sources.count) authorized folder" + (sources.count == 1 ? "." : "s.")
    }

    func selectLibraryScope(_ source: SourceFolder?) {
        let next: LibraryScope = source.map { .source($0.id) } ?? .allAuthorized
        guard next != libraryScope else {
            refreshDashboard()
            return
        }
        libraryScope = next
        // Results from another folder are more dangerous than stale: they
        // look like evidence for the selected folder. Clear them immediately,
        // then rerun the current query against the new scope if one exists.
        searchResults = []
        searchFoundNothing = false
        refreshDashboard()
        if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runSearch()
        }
    }

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
    private var reprobeObserver: NSObjectProtocol?
    private var dashboardRefreshTask: Task<Void, Never>?
    private var lastDashboardRefreshAt: Date = .distantPast

    /// Coalesce live-event dashboard refreshes to at most one per second.
    /// Actions that need an immediate refresh (apply, undo, cleanup unwind)
    /// call `refreshDashboard()` directly and reset the timer window.
    func scheduleDashboardRefresh() {
        guard dashboardRefreshTask == nil else { return }
        let delay = max(0, 1.0 - Date().timeIntervalSince(lastDashboardRefreshAt))
        dashboardRefreshTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.dashboardRefreshTask = nil
            self.lastDashboardRefreshAt = Date()
            self.refreshDashboard()
        }
    }
    /// A requested analysis that is waiting for the current one to unwind.
    /// Set when a rule/setting change asks for a replacement while a run is
    /// active; consumed at unwind so the promise "restarting after this pass"
    /// is actually kept.
    private var pendingReplacementSource: SourceFolder?
    /// Root paths owned by the active analysis, so pausing an unrelated
    /// folder does not kill a run that never touched it.
    private var activeAnalysisPaths: Set<String> = []
    private var changedGroupIDsUpdatedAt: Date?

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
        let storedProfile = LocalModelProfile(
            rawValue: UserDefaults.standard.string(forKey: "local-model-profile-v1") ?? "fast") ?? .fast
        // Migrate older builds that persisted an independent Tier-2 toggle.
        // The visible quality choice now owns this behavior deterministically.
        self.localEmbeddingsEnabled = storedProfile != .fast
        self.localModelProfile = storedProfile
        UserDefaults.standard.set(storedProfile != .fast, forKey: "tier2-enabled-v1")
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
        if catalogReady {
            log("library ready · live changes monitored · missing checks are manual")
        }
        if reprobeObserver == nil {
            reprobeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.reprobeUnavailableSources()
                }
            }
        }
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
            // A downloaded checkpoint is not enough: the selected profile is
            // Ready only when its actual offline runtime preflight succeeds.
            self.specialistReadyIDs = readiness.specialistRuntimeIDs
            self.isTier2Provisioned = readiness.coreML
                || readiness.legacyRuntime
                || !readiness.specialistRuntimeIDs.isEmpty
            if let semantic = LocalModelStack.semanticModel(for: self.localModelProfile),
               readiness.specialistRuntimeIDs.contains(semantic.id) {
                self.tier2Status = semantic.id == LocalModelStack.siglip2Base.id
                    ? "Tier-2 ready — SigLIP2 Base NaFlex"
                    : "Tier-2 ready — SigLIP2 So400m NaFlex"
            } else if readiness.coreML {
                self.tier2Status = "Tier-2 ready — Core ML MobileCLIP"
            } else if readiness.legacyRuntime {
                self.tier2Status = "Tier-2 ready — offline Python embeddings"
            } else if readiness.legacyClip || readiness.legacyMiniLM {
                self.tier2Status = "Checkpoint files found; offline Python runtime is unavailable"
            } else if !readiness.specialistIDs.isEmpty {
                self.tier2Status = "Specialist checkpoints found; their offline runtime is unavailable"
            } else {
                self.tier2Status = "Tier-2 not provisioned — use the setup command in Settings › Local models"
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

    /// Explicit recovery from "keychain hell": when the stored catalog key's
    /// Keychain ACL no longer trusts this app's code signature (usually the
    /// result of ad-hoc-signed rebuilds), every launch prompts and fails.
    /// This action locks the old encrypted catalog files aside (never deletes
    /// them), removes the unreadable app-owned key item, and opens a new
    /// encrypted catalog created by THIS signed binary — whose ACL is then
    /// stable across rebuilds signed with the same identity.
    func resetCatalogKeyAndStartFresh() {
        guard catalog == nil, !catalogMigrationRequired else { return }
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        do {
            let active = catalogURL
            if fm.fileExists(atPath: active.path) {
                let locked = active.deletingLastPathComponent()
                    .appendingPathComponent("catalog.locked-\(stamp).db")
                try fm.moveItem(at: active, to: locked)
                for sidecar in ["-shm", "-wal"] {
                    let source = URL(fileURLWithPath: active.path + sidecar)
                    if fm.fileExists(atPath: source.path) {
                        try? fm.moveItem(at: source, to: URL(fileURLWithPath: locked.path + sidecar))
                    }
                }
                log("previous catalog locked aside as \(locked.lastPathComponent); it was never deleted")
            }
            try CatalogKeychain.destroyAppOwned()
            UserDefaults.standard.removeObject(forKey: Self.activeCatalogFilenameKey)
            catalogError = nil
            catalogMigrationAttempted = false
            // Authorized folders are kept: their bookmarks still resolve, so
            // the fresh catalog can be repopulated without re-picking folders.
            openCatalogIfNeeded()
            refreshDashboard()
            if catalogReady {
                log("fresh encrypted catalog ready; run Clean Up to index your folders again")
            }
        } catch {
            catalogError = error.localizedDescription
            log("catalog key reset failed: \(error); nothing was deleted")
        }
    }

    // MARK: - Security-scoped source access

    func addSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Indexing is read-only. Files move only when you explicitly apply a plan — and every move is undoable."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                guard let data = try? url.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil), !data.isEmpty else {
                    self.log("could not persist folder permission: \(url.path)")
                    continue
                }
                self.bookmarkDataByPath[url.path] = data
                if !self.sources.contains(where: { $0.path == url.path }) {
                    self.sources.append(SourceFolder(id: UUID(), path: url.path))
                }
                do {
                    try self.catalog?.restoreRootScope(root: url.path)
                } catch {
                    self.log("could not restore \(url.path) into the catalog: \(error); run an analysis to bring its files back")
                }
            }
            self.saveBookmarks()
            self.restartLiveCoordinator()
            // Re-adding a previously removed root flips rows unscoped →
            // pending, which changes the coverage and cataloged counts.
            self.refreshDashboard()
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
            // Only stop the run when the paused folder is part of it. Killing
            // a scoped analysis of a different folder would look like the
            // app randomly abandoning its work.
            if activeAnalysisPaths.contains(source.path) {
                activeIndexCancellation?.cancel(reason: .paused)
                log("paused folder is part of the current analysis · stopping after this file…")
            } else {
                log("paused \(source.path) · the current analysis is unaffected")
            }
        }
        savePausedPaths()
        restartLiveCoordinator()
        refreshDashboard()
    }

    func removeSource(_ source: SourceFolder) {
        if isIndexing { activeIndexCancellation?.cancel(reason: .removed) }
        if libraryScopeSource?.id == source.id {
            libraryScope = .allAuthorized
        }
        do {
            try catalog?.markRootUnscoped(root: source.path)
        } catch {
            // If unscoping fails, the removed folder's rows would keep showing
            // up everywhere as if it were still authorized — say so loudly.
            log("could not remove \(source.path) from the catalog view: \(error)")
        }
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
        panel.message = "Choose the replacement folder. Analysis reads only; files move only when you apply a plan."
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

    /// Resolve a stored security-scoped bookmark and run `body`
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

    /// A transient bookmark failure (network volume not yet mounted, briefly
    /// locked external drive) must not brand a folder "Needs permission"
    /// forever. Re-probe flagged folders whenever the app becomes active; a
    /// healed lease clears the flag and live indexing resumes for it.
    func reprobeUnavailableSources() {
        guard !sourcesNeedingReauthorization.isEmpty, !isIndexing, !isReconciling else { return }
        var healed: [SourceFolder] = []
        for source in sources where sourcesNeedingReauthorization.contains(source.path) {
            if sourceLease(for: source) != nil {
                healed.append(source)
            }
        }
        guard !healed.isEmpty else { return }
        log("folder access recovered for \((healed.map { ($0.path as NSString).lastPathComponent }).joined(separator: ", "))")
        restartLiveCoordinator()
        refreshDashboard()
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
                // Every delivered batch fires this callback. The pending-event
                // counter updates instantly; the full dashboard refresh (≈9
                // catalog queries plus section reloads) is debounced so a live
                // file-change storm cannot stall the main actor.
                self.scheduleDashboardRefresh()
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

    /// Verify known catalog rows against the live authorized folders without
    /// re-running extraction or local models. Full analysis remains explicit.
    func reconcileAuthorizedSources(source scopedSource: SourceFolder? = nil) {
        guard catalogReady, let catalog, !isReconciling, !isIndexing else { return }
        let candidateSources = scopedSource.map { [$0] } ?? sources
        let authorized: [(sourcePath: String, lease: SecurityScopedBookmarkLease)] = candidateSources
            .filter { !pausedPaths.contains($0.path) && !sourcesNeedingReauthorization.contains($0.path) }
            .compactMap { source in sourceLease(for: source).map { (source.path, $0) } }
        guard !authorized.isEmpty else { return }

        isReconciling = true
        let scopeLabel = scopedSource.map { ($0.path as NSString).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "authorized folders"
        log("checking known catalog paths under \(scopeLabel)…")
        Task.detached(priority: .utility) { [weak self, catalog, authorized] in
            let broker = SourceBroker()
            let rows = (try? catalog.allFiles(statuses: ["indexed"], roots: authorized.map(\.sourcePath))) ?? []
            var markedMissing = 0
            var skippedInaccessible = 0
            for row in rows {
                // Rows outside every currently authorized root are left alone:
                // a paused or de-authorized folder is not evidence that its
                // files disappeared.
                guard let scope = authorized.first(where: {
                    SourceBroker.isPath(row.path, under: $0.sourcePath)
                }) else { continue }
                let outcome = SourceReconciler.classify(
                    leaseTargetURL: scope.lease.targetURL(
                        for: row.path, originalRootPath: scope.sourcePath),
                    identity: { try broker.identity(at: $0) })
                switch outcome {
                case .current:
                    break
                case .movedOrDeleted:
                    try? catalog.markMissing(path: row.path)
                    markedMissing += 1
                case .permissionDenied:
                    try? catalog.recordAccessBackoff(prefix: row.path, reason: "permission-denied")
                    skippedInaccessible += 1
                case .unavailable:
                    skippedInaccessible += 1
                }
            }
            let missingSnapshot = markedMissing
            let skippedSnapshot = skippedInaccessible
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isReconciling = false
                self.log(missingSnapshot == 0 && skippedSnapshot == 0
                         ? "missing check complete · known paths are current"
                         : "missing check complete · \(missingSnapshot) known path(s) moved or deleted"
                           + (skippedSnapshot == 0 ? "" : " · \(skippedSnapshot) unreadable, kept as-is"))
                self.refreshDashboard()
            }
        }
    }

    // MARK: - Apply to Finder (explicit, journaled, undoable)

    /// Build the preview plan for turning one virtual group into a real
    /// folder. Nothing moves until `confirmApply()` runs.
    func prepareApply(group: SmartOrganizationGroup, destinationRootPath: String? = nil) {
        guard catalogReady, let catalog, !isApplyOperationInProgress,
              !isReconciling, !isPreparingPlan, pendingApplyPlan == nil else {
            if isPreparingPlan || pendingApplyPlan != nil {
                log("an apply preview is already being prepared or shown")
            }
            return
        }
        isPreparingPlan = true
        applyReplanGeneration += 1
        let generation = applyReplanGeneration
        let roots = sources.map(\.path)
        Task.detached(priority: .userInitiated) { [weak self, catalog, group, roots, destinationRootPath, generation] in
            do {
                let plan = try OrganizationApplier.plan(
                    group: group,
                    pathFor: { fileID in (try? catalog.fileRow(id: fileID))?.path ?? "" },
                    sourceRoots: roots,
                    destinationRootPath: destinationRootPath)
                await MainActor.run { [weak self] in
                    guard let self, self.applyReplanGeneration == generation else { return }
                    self.isPreparingPlan = false
                    if plan.items.isEmpty {
                        // Re-apply of a settled group must not open a dead
                        // "Move 0 Files" sheet — say what happened instead.
                        self.lastApplyMessage = Self.emptyPlanMessage(plan: plan)
                        self.lastApplyFailureReport = nil
                    } else {
                        self.pendingApplyPlan = plan
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.applyReplanGeneration == generation else { return }
                    self.isPreparingPlan = false
                    self.lastApplyMessage = "Could not prepare apply: \(error.localizedDescription)"
                    self.log("could not prepare apply: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func emptyPlanMessage(plan: OrganizationApplier.Plan) -> String {
        if !plan.missingPaths.isEmpty {
            return "No files from “\(plan.groupTitle)” are available to move right now (\(plan.missingPaths.count) unavailable)."
        }
        return "All \(plan.alreadyInPlace) files from “\(plan.groupTitle)” are already in “\(plan.folderName)” — nothing to move."
    }

    /// Rebuild the preview when the user chooses a different authorized root.
    /// The sheet stays presented and the plan swaps in place once replanning
    /// finishes; nil-ing the plan first would dismiss and re-present the sheet.
    /// Replanning is intentional: conflict-free destination names depend on the
    /// live contents of the selected destination.
    func replanApply(to rootPath: String) {
        guard !isApplyOperationInProgress,
              let currentPlan = pendingApplyPlan,
              let group = smartGroups.first(where: { $0.id == currentPlan.groupID }),
              currentPlan.candidateRootPaths.contains(rootPath),
              rootPath != currentPlan.destinationRootPath else { return }
        guard catalogReady, let catalog else { return }
        applyReplanGeneration += 1
        let generation = applyReplanGeneration
        isPreparingPlan = true
        let roots = sources.map(\.path)
        Task.detached(priority: .userInitiated) { [weak self, catalog, group, roots, rootPath, generation] in
            do {
                let plan = try OrganizationApplier.plan(
                    group: group,
                    pathFor: { fileID in (try? catalog.fileRow(id: fileID))?.path ?? "" },
                    sourceRoots: roots,
                    destinationRootPath: rootPath)
                await MainActor.run { [weak self] in
                    guard let self, self.applyReplanGeneration == generation else { return }
                    self.isPreparingPlan = false
                    self.pendingApplyPlan = plan
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.applyReplanGeneration == generation else { return }
                    self.isPreparingPlan = false
                    self.log("apply preview failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancelApply() {
        applyReplanGeneration += 1
        pendingApplyPlan = nil
    }

    /// Execute the confirmed plan with fresh security-scoped leases, then
    /// refresh the dashboard so the group reflects the new locations.
    func confirmApply(excluding fileIDs: Set<String> = []) {
        guard let pendingPlan = pendingApplyPlan, catalogReady, let catalog,
              !isApplyOperationInProgress, !isReconciling else { return }
        let plan = pendingPlan.excluding(fileIDs: fileIDs)
        guard !plan.items.isEmpty else { return }
        applyReplanGeneration += 1
        pendingApplyPlan = nil
        isApplyOperationInProgress = true
        let bookmarkData = bookmarkDataByPath
        log("applying \"\(plan.groupTitle)\" · moving \(plan.items.count) files…")
        Task.detached(priority: .userInitiated) { [weak self, catalog, plan, bookmarkData] in
            do {
                let outcome = try OrganizationApplier.apply(
                    plan: plan,
                    leaseForRoot: { rootPath in
                        try SecurityScopedBookmarkLease(bookmarkData: bookmarkData[rootPath])
                    },
                    catalog: catalog)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isApplyOperationInProgress = false
                    self.lastApplyMessage = outcome.succeeded
                        ? "Moved \(outcome.moved) files to \(outcome.destinationFolderPath)"
                        : "Moved \(outcome.moved) of \(outcome.moved + outcome.failures.count) files · \(outcome.failures.count) failed"
                    self.lastApplyFailureReport = outcome.succeeded ? nil : ApplyFailureReport(
                        title: "Failed moves for \"\(plan.groupTitle)\"",
                        failures: outcome.failures)
                    self.log("applied \"\(plan.groupTitle)\" · \(outcome.destinationFolderPath)")
                    self.refreshDashboard()
                    self.updateUndoAvailability()
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.isApplyOperationInProgress = false
                    self.log("apply failed: \(error.localizedDescription)")
                    self.lastApplyMessage = "Apply failed: \(error.localizedDescription)"
                    self.lastApplyFailureReport = nil
                }
            }
        }
    }

    func undoLastApply() {
        guard catalogReady, let catalog, !isApplyOperationInProgress else { return }
        isApplyOperationInProgress = true
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
                self.isApplyOperationInProgress = false
                if let outcome {
                    self.lastApplyMessage = outcome.succeeded
                        ? "Undo complete · \(outcome.restored) files restored"
                        : "Undo restored \(outcome.restored) files · \(outcome.failures.count) failed"
                    self.lastApplyFailureReport = outcome.succeeded ? nil : ApplyFailureReport(
                        title: "Failed undo restores",
                        failures: outcome.failures)
                    self.log(self.lastApplyMessage ?? "")
                } else {
                    self.lastApplyMessage = "Nothing left to undo"
                    self.lastApplyFailureReport = nil
                }
                self.refreshDashboard()
                self.updateUndoAvailability()
            }
        }
    }

    private func updateUndoAvailability() {
        guard let catalog else {
            canUndoApply = false
            undoBatchFileCount = 0
            return
        }
        if let batchID = (try? catalog.latestApplyBatchID()) ?? nil {
            canUndoApply = true
            // "Undo what, exactly?" — surface the batch size so Undo after a
            // restart is not a blind action.
            undoBatchFileCount = ((try? catalog.applyBatchEntries(batchID: batchID)) ?? []).count
        } else {
            canUndoApply = false
            undoBatchFileCount = 0
        }
    }

    func shutdown() {
        activeIndexCancellation?.cancel(reason: .shutdown)
        modelStatusTask?.cancel()
        searchTask?.cancel()
        stopLiveCoordinator()
        if let observer = reprobeObserver {
            NotificationCenter.default.removeObserver(observer)
            reprobeObserver = nil
        }
    }

    func startIndexing() {
        if isIndexing {
            pendingReplacementSource = nil
            activeIndexCancellation?.cancel(reason: .replaced)
            log("settings changed · restarting analysis over all folders after this pass…")
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
            pendingReplacementSource = source
            activeIndexCancellation?.cancel(reason: .replaced)
            let name = (source.path as NSString).lastPathComponent
            log("restarting analysis of \(name) after this pass…")
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
        guard !isReconciling else {
            // The startup folder check is a short lstat pass; the home screen
            // shows "Checking known files…" while it runs. Ask for a retry
            // instead of racing two passes over the same roots.
            log("still checking known files — try again in a moment")
            return
        }
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
        activeAnalysisPaths = Set(jobs.map(\.0.path))
        // Snapshot group sizes so completion can show exactly which groups the
        // cleanup created or grew ("what did it just organize?").
        let groupSizesBefore = Dictionary(uniqueKeysWithValues: smartGroups.map { ($0.id, $0.fileIDs.count) })
        let runStartedAt = Date()
        log("cleanup started · \(scopeLabel)")

        Task.detached(priority: .userInitiated) { [weak self, jobs, session, token, scopeLabel, groupSizesBefore, catalog, runStartedAt] in
            var unavailableSources: [String] = []
            var completionReasons: [String] = []
            var folderReports: [CleanupFolderReport] = []
            for (source, lease) in jobs {
                if token.isCancelled { break }
                do {
                    // Baseline of rows the catalog already knew for this root,
                    // so the report can say "nothing new" with evidence.
                    let knownBefore = (try? catalog.indexedFileCount(under: source.path)) ?? 0
                    let result = try session.indexRoot(lease.url, cancellation: token) { progress in
                        Task { @MainActor [weak self] in
                            self?.log("cleanup \(scopeLabel) · \(progress.rootPath)… \(progress.scanned) files scanned")
                        }
                    }
                    completionReasons.append("\(source.path)=\(result.completion.rawValue)")
                    folderReports.append(CleanupFolderReport(
                        rootPath: source.path,
                        knownBefore: knownBefore,
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
                self.activeAnalysisPaths = []
                self.refreshDashboard()
                if !reportSnapshot.isEmpty {
                    self.lastCleanupReport = CleanupReport(
                        finishedAt: Date(),
                        duration: Date().timeIntervalSince(runStartedAt),
                        folders: reportSnapshot)
                    let sizesAfter = Dictionary(uniqueKeysWithValues: self.smartGroups.map { ($0.id, $0.fileIDs.count) })
                    self.changedGroupIDs = Set(sizesAfter.filter { id, count in
                        (groupSizesBefore[id] ?? 0) < count
                    }.keys)
                    self.changedGroupIDsUpdatedAt = Date()
                }
                let processedTotal = reportSnapshot.reduce(0) { $0 + $1.processed }
                let missingTotal = reportSnapshot.reduce(0) { $0 + $1.missingMarked }
                if token.isCancelled {
                    self.log("analysis stopped · \(scopeLabel) · \(processedTotal) new or changed before stop")
                } else if completionSnapshot.contains(where: { $0.hasSuffix("=rootUnavailable") }) {
                    self.log("analysis finished with an unavailable folder · \(scopeLabel) · \(processedTotal) new or changed")
                } else {
                    self.log("analysis complete · \(scopeLabel) · \(processedTotal) new or changed"
                             + (missingTotal == 0 ? "" : " · \(missingTotal) missing"))
                }
                self.restartLiveCoordinator()
                // A requested replacement (rule/setting change mid-run) must
                // actually run, or the status line's promise is a lie. Only a
                // `.replaced` stop restarts; a user cancel stays stopped.
                let replacement = (token.reason == .replaced) ? self.pendingReplacementSource : nil
                self.pendingReplacementSource = nil
                if let replacement {
                    self.startIndexing(source: replacement)
                } else if token.reason == .replaced {
                    self.startIndexing()
                }
            }
        }
    }

    func refreshDashboard() {
        guard let catalog else { return }
        let scopeRoots = libraryScopeRoots
        // "· just updated" chips stop being true once the data has moved on.
        if let updated = changedGroupIDsUpdatedAt,
           Date().timeIntervalSince(updated) > 600,
           !changedGroupIDs.isEmpty {
            changedGroupIDs = []
            changedGroupIDsUpdatedAt = nil
        }
        do {
            // The dashboard only needs aggregate graph counts. Do not load the
            // full organization graph or every similarity family onto the main
            // actor just to refresh counters on a huge catalog.
            dashboard = try catalog.dashboard(roots: scopeRoots)
            reviewItems = try catalog.reviewItems(limit: 200, roots: scopeRoots)
            learnedRules = try catalog.listRules()
            similarityClusters = try catalog.boundedSimilarityClusters(roots: scopeRoots, limit: 200)
            smartGroups = try catalog.smartOrganizationGroups(roots: scopeRoots)
            projectSummaries = try catalog.projectSemanticSummaries(limit: 128, roots: scopeRoots)
            coverage = try catalog.coverage(roots: scopeRoots,
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
        let scope = libraryScope
        let scopeRoots = libraryScopeRoots
        guard let catalog else {
            sectionFiles = []
            return
        }
        Task.detached(priority: .userInitiated) { [weak self, catalog, section, scope, scopeRoots] in
            let files = Self.sectionFileSummaries(catalog: catalog, section: section, roots: scopeRoots)
            await MainActor.run { [weak self] in
                guard let self, self.selectedSection == section, self.libraryScope == scope else { return }
                self.sectionFiles = files
            }
        }
    }

    private nonisolated static func sectionFileSummaries(
        catalog: Catalog, section: LibrarySection, roots: [String]
    ) -> [Catalog.FileSummary] {
        switch section {
        case .screenshots:
            let plural = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshots", roots: roots, limit: 200)) ?? []
            let singular = (try? catalog.boundedFileSummaries(categoryPrefix: "Screenshot", roots: roots, limit: 200)) ?? []
            return Array(Dictionary((plural + singular).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                .values.sorted { $0.path < $1.path }.prefix(200))
        case .school:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "School", roots: roots, limit: 200)) ?? []
        case .projects:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "Projects", roots: roots, limit: 200)) ?? []
        case .documents:
            return (try? catalog.boundedFileSummaries(categoryPrefix: "Documents", roots: roots, limit: 200)) ?? []
        case .media:
            return (try? catalog.boundedFileSummaries(kinds: [.audio, .video], roots: roots, limit: 200)) ?? []
        case .duplicates:
            return (try? catalog.boundedFileSummaries(duplicateOnly: true, roots: roots, limit: 200)) ?? []
        case .missing:
            return (try? catalog.boundedFileSummaries(status: "missing", roots: roots, limit: 200)) ?? []
        default:
            return (try? catalog.boundedFileSummaries(roots: roots, limit: 200)) ?? []
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
            searchFoundNothing = false
            return
        }
        isSearching = true
        searchFoundNothing = false
        searchResults = []
        let enabled = localEmbeddingsEnabled
        let profile = localModelProfile
        let mode = searchMode
        let providerKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        let scopeRoots = libraryScopeRoots
        let work = Task.detached(priority: .userInitiated) {
            Self.searchResults(catalog: catalog, query: normalizedQuery, mode: mode,
                               enableLocalEmbeddings: enabled, localModelProfile: profile,
                               embeddingProviderKind: providerKind, roots: scopeRoots)
        }
        searchTask = Task { @MainActor [weak self] in
            let results = await work.value
            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
            self.searchFoundNothing = results.isEmpty
            self.searchResults = results
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration += 1
        query = ""
        searchResults = []
        isSearching = false
        searchFoundNothing = false
    }

    /// Reveal a cataloged file in Finder with it selected. Read-only — Finder
    /// shows the live file wherever it actually is.
    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private nonisolated static func searchResults(
        catalog: Catalog,
        query: String,
        mode: String,
        enableLocalEmbeddings: Bool,
        localModelProfile: LocalModelProfile,
        embeddingProviderKind: String?,
        roots: [String]
    ) -> [SearchResult] {
        let service = SearchService(
            catalog: catalog,
            enableLocalEmbeddings: enableLocalEmbeddings,
            localModelProfile: localModelProfile,
            embeddingProviderKind: embeddingProviderKind)
        func exactResults() -> [SearchResult] {
            ((try? service.search(query, roots: roots)) ?? []).map { hit in
                SearchResult(id: hit.fileID, path: hit.path,
                             snippet: (hit.snippet ?? "").replacingOccurrences(of: "\n", with: " "),
                             modeLabel: "match")
            }
        }
        func semanticResults() -> [SearchResult] {
            ((try? service.semanticSearch(query: query, limit: 200, roots: roots)) ?? [])
                .filter { Self.pathIsInScope($0.path, roots: roots) }
                .prefix(20).map { hit in
                SearchResult(id: hit.fileID, path: hit.path, snippet: "",
                             modeLabel: String(format: "semantic %.0f%%", hit.score * 100))
            }
        }
        func clipResults() -> [SearchResult] {
            ((try? service.clipTextToImageSearch(query: query, limit: 200, roots: roots)) ?? [])
                .filter { Self.pathIsInScope($0.path, roots: roots) }
                .prefix(20).map { hit in
                SearchResult(id: hit.fileID, path: hit.path, snippet: "",
                             modeLabel: String(format: "visual %.0f%%", hit.score * 100))
            }
        }

        switch mode {
        case "exact": return exactResults()
        case "semantic":
            let rows = semanticResults()
            if !rows.isEmpty { return rows }
            // An explicit mode must never look like "search is broken": when
            // its models are not enabled/available, say so and fall back.
            return [SearchResult(id: "note", path: "", snippet: "",
                                 modeLabel: "semantic search needs downloaded local models — showing exact matches for “\(query)”")] + exactResults()
        case "clipText":
            let rows = clipResults()
            if !rows.isEmpty { return rows }
            return [SearchResult(id: "note", path: "", snippet: "",
                                 modeLabel: "visual search needs downloaded local models — showing exact matches for “\(query)”")] + exactResults()
        default:
            // Auto prefers the richest available signal, then falls back.
            let semantic = semanticResults()
            if !semantic.isEmpty { return semantic }
            let clip = clipResults()
            if !clip.isEmpty { return clip }
            return exactResults()
        }
    }

    private nonisolated static func pathIsInScope(_ path: String, roots: [String]) -> Bool {
        guard !path.isEmpty, !roots.isEmpty else { return false }
        return roots.contains { root in
            let normalized = root.count > 1 && root.hasSuffix("/")
                ? String(root.dropLast()) : root
            return normalized == "/"
                ? path.hasPrefix("/")
                : path == normalized || path.hasPrefix(normalized + "/")
        }
    }

    /// Privacy indicators derived from ACTUAL state where possible (plan §45).
    func privacyIndicators() -> [(String, Bool)] {
        let sandboxed = amISandboxed()
        return [
            ("App Sandbox enabled", sandboxed),
            ("Read-only unless you apply a plan", true), // SourceBroker O_RDONLY|O_NOFOLLOW; moves only via journaled apply
            ("Network only for explicit model setup", true),
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
        latestStatusEvent = StatusEvent(message: s, timestamp: Date())
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
