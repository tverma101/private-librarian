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
MAGIC = "Sources/LibrarianApp/MagicViews.swift"

replace_once(
    APP,
    '''    func startIndexing() {
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
                        self?.log("cleanup… \\(progress.scanned) files scanned")
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
''',
    '''    func startIndexing() {
        guard !isIndexing else { return }
        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources
            .filter { !pausedPaths.contains($0.path) }
            .compactMap { source in sourceLease(for: source).map { (source, $0) } }
        startCleanup(jobs: jobs, scopeLabel: "all authorized folders")
    }

    func startIndexing(source: SourceFolder) {
        guard !isIndexing, !pausedPaths.contains(source.path) else { return }
        guard let lease = sourceLease(for: source) else {
            log("folder needs reauthorization before cleanup: \\(source.path)")
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
        log("cleanup started · \\(scopeLabel)")

        Task.detached(priority: .userInitiated) { [weak self, jobs, session, token, scopeLabel] in
            for (_, lease) in jobs {
                if token.isCancelled { break }
                _ = try? session.indexRoot(lease.url, cancellation: token) { progress in
                    Task { @MainActor [weak self] in
                        self?.log("cleanup \\(scopeLabel)… \\(progress.scanned) files scanned")
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeIndexCancellation = nil
                self.isIndexing = false
                self.log(token.isCancelled ? "cleanup stopped" : "cleanup complete · \\(scopeLabel)")
                self.refreshDashboard()
            }
        }
    }
''',
)

replace_once(
    MAGIC,
    '''                    Button(model.isIndexing ? "Stop Cleanup" : "Clean Up My Mac") {
                        if model.isIndexing { model.cancelIndexing() } else { model.startIndexing() }
                    }
                    .disabled(!model.isIndexing && (model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) }))
''',
    '''                    if model.isIndexing {
                        Button("Stop Cleanup") { model.cancelIndexing() }
                    } else {
                        Menu("Clean Up") {
                            Button("All Authorized Folders") { model.startIndexing() }
                            Divider()
                            ForEach(model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }) { source in
                                let name = (source.path as NSString).lastPathComponent
                                Button("Only \\(name.isEmpty ? source.path : name)") {
                                    model.startIndexing(source: source)
                                }
                            }
                        }
                        .disabled(model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) || model.needsReauthorization($0) })
                    }
''',
)

print("folder-only cleanup scope applied")
