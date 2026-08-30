#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if new in text:
        return
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one old block in {path}, found {count}")
    p.write_text(text.replace(old, new, 1))


APP = "Sources/LibrarianApp/PrivateLibrarianApp.swift"
LIVE = "Sources/LibrarianCore/LiveIndexCoordinator.swift"
MAGIC = "Sources/LibrarianApp/MagicViews.swift"
CLI = "Sources/librarian-cli/main.swift"

replace_once(
    APP,
    """    private var liveCoordinator: LiveIndexCoordinator?\n    private var liveAccessLeases: [String: SecurityScopedBookmarkLease] = [:]\n""",
    """    private var liveCoordinator: LiveIndexCoordinator?\n    private var liveAccessLeases: [String: SecurityScopedBookmarkLease] = [:]\n    private var activeIndexCancellation: IndexCancellationToken?\n""",
)

replace_once(
    APP,
    """    func togglePaused(_ source: SourceFolder) {\n        if pausedPaths.contains(source.path) {\n            pausedPaths.remove(source.path)\n        } else {\n            pausedPaths.insert(source.path)\n        }\n        savePausedPaths()\n        restartLiveCoordinator()\n        refreshDashboard()\n    }\n""",
    """    func togglePaused(_ source: SourceFolder) {\n        let isPausing: Bool\n        if pausedPaths.contains(source.path) {\n            pausedPaths.remove(source.path)\n            isPausing = false\n        } else {\n            pausedPaths.insert(source.path)\n            isPausing = true\n        }\n        if isPausing, isIndexing {\n            activeIndexCancellation?.cancel()\n            log(\"stopping current cleanup after this file…\")\n        }\n        savePausedPaths()\n        restartLiveCoordinator()\n        refreshDashboard()\n    }\n""",
)

replace_once(
    APP,
    """    func removeSource(_ source: SourceFolder) {\n        try? catalog?.markRootUnscoped(root: source.path)\n""",
    """    func removeSource(_ source: SourceFolder) {\n        if isIndexing { activeIndexCancellation?.cancel() }\n        try? catalog?.markRootUnscoped(root: source.path)\n""",
)

replace_once(
    APP,
    """    func startIndexing() {\n        guard let indexer = makeIndexer(), !isIndexing else { return }\n        isIndexing = true\n        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources\n            .filter { !pausedPaths.contains($0.path) }\n            .compactMap { source in sourceLease(for: source).map { (source, $0) } }\n        guard !jobs.isEmpty else {\n            isIndexing = false\n            log(\"no authorized source folders available for indexing\")\n            return\n        }\n\n        Task.detached(priority: .userInitiated) { [weak self, jobs, indexer] in\n            for (_, lease) in jobs {\n                _ = try? indexer.indexRoot(lease.url) { progress in\n                    Task { @MainActor [weak self] in\n                        self?.log(\"indexing… \\(progress.processed)/\\(progress.total)\")\n                    }\n                }\n            }\n            await MainActor.run { [weak self] in\n                self?.isIndexing = false\n                self?.log(\"indexing complete\")\n                self?.refreshDashboard()\n            }\n        }\n    }\n""",
    """    func cancelIndexing() {\n        guard isIndexing else { return }\n        activeIndexCancellation?.cancel()\n        log(\"stopping cleanup after the current file…\")\n    }\n\n    func startIndexing() {\n        guard let indexer = makeIndexer(), let catalog, !isIndexing else { return }\n        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources\n            .filter { !pausedPaths.contains($0.path) }\n            .compactMap { source in sourceLease(for: source).map { (source, $0) } }\n        guard !jobs.isEmpty else {\n            log(\"no authorized source folders available for cleanup\")\n            return\n        }\n\n        var sessionOptions = ScalableIndexSession.Options()\n        sessionOptions.excludedPaths = effectiveExcludedPaths\n        sessionOptions.excludedDirectoryNames = OnboardingExclusions.defaultDirectoryNames\n        sessionOptions.enablePersistentEmbeddingWorker = localEmbeddingsEnabled\n        sessionOptions.respectAccessBackoff = false // explicit user cleanup retries permission state\n        let session = ScalableIndexSession(\n            broker: SourceBroker(), catalog: catalog, indexer: indexer, options: sessionOptions)\n        let token = IndexCancellationToken()\n        activeIndexCancellation = token\n        isIndexing = true\n        log(\"cleanup started\")\n\n        Task.detached(priority: .userInitiated) { [weak self, jobs, session, token] in\n            for (_, lease) in jobs {\n                if token.isCancelled { break }\n                _ = try? session.indexRoot(lease.url, cancellation: token) { progress in\n                    Task { @MainActor [weak self] in\n                        self?.log(\"cleanup… \\(progress.scanned) files scanned\")\n                    }\n                }\n            }\n            await MainActor.run { [weak self] in\n                guard let self else { return }\n                self.activeIndexCancellation = nil\n                self.isIndexing = false\n                self.log(token.isCancelled ? \"cleanup stopped\" : \"cleanup complete\")\n                self.refreshDashboard()\n            }\n        }\n    }\n""",
)

replace_once(
    MAGIC,
    """                    Button(model.isIndexing ? \"Indexing…\" : \"Index Now\") { model.startIndexing() }\n                        .disabled(model.isIndexing || model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) })\n""",
    """                    Button(model.isIndexing ? \"Stop Cleanup\" : \"Clean Up My Mac\") {\n                        if model.isIndexing { model.cancelIndexing() } else { model.startIndexing() }\n                    }\n                    .disabled(!model.isIndexing && (model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) }))\n""",
)

# One shared automatic-root scanner for directory events and whole-root reconciliation.
replace_once(
    LIVE,
    """    private func processSinglePath(_ path: String) throws -> (changedID: String?, removedID: String?) {\n""",
    """    private func automaticRootSession() -> ScalableIndexSession {\n        var sessionOptions = ScalableIndexSession.Options()\n        sessionOptions.excludedPaths = options.excludedPaths\n        sessionOptions.excludedDirectoryNames = options.excludedDirectoryNames\n        sessionOptions.respectAccessBackoff = true\n        return ScalableIndexSession(\n            broker: broker, catalog: catalog, indexer: indexer, options: sessionOptions)\n    }\n\n    private func processSinglePath(_ path: String) throws -> (changedID: String?, removedID: String?) {\n""",
)

replace_once(
    LIVE,
    """            if broker.isDirectory(at: path) {\n                _ = try indexer.indexRoot(URL(fileURLWithPath: path))\n                return (nil, nil)\n            }\n""",
    """            if broker.isDirectory(at: path) {\n                _ = try automaticRootSession().indexRoot(URL(fileURLWithPath: path))\n                return (nil, nil)\n            }\n""",
)

replace_once(
    LIVE,
    """        for root in snapshot where FileManager.default.fileExists(atPath: root.path) {\n            _ = try? indexer.indexRoot(root)\n        }\n""",
    """        for root in snapshot where FileManager.default.fileExists(atPath: root.path) {\n            _ = try? automaticRootSession().indexRoot(root)\n        }\n""",
)

replace_once(
    CLI,
    """        let t0 = Date()\n        let n = try indexer.indexRoot(url)\n        let groups = try indexer.computeDuplicateGroups()\n        print(\"indexed \\(n) files in \\(String(format: \"%.2f\", Date().timeIntervalSince(t0)))s\")\n""",
    """        let t0 = Date()\n        var sessionOptions = ScalableIndexSession.Options()\n        sessionOptions.enablePersistentEmbeddingWorker = hasFlag(\"--tier2\")\n        let session = ScalableIndexSession(\n            broker: broker, catalog: catalog, indexer: indexer, options: sessionOptions)\n        let result = try session.indexRoot(url)\n        let groups = try indexer.computeDuplicateGroups()\n        print(\"indexed \\(result.processed) files (\\(result.scanned) scanned) in \\(String(format: \"%.2f\", Date().timeIntervalSince(t0)))s\")\n""",
)

print("scalable cleanup wiring applied")
