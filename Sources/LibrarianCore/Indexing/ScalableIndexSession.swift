import Foundation

/// Cooperative cancellation shared by the UI and a long root-index session.
/// Cancellation is checked between discovered files and before missing-file
/// reconciliation. A currently executing atomic per-file commit is never torn.
public final class IndexCancellationToken: @unchecked Sendable {
    public enum CancellationReason: String, Sendable, Equatable {
        case cancelled
        case paused
        case removed
        case shutdown
        case replaced
    }

    private let lock = NSLock()
    private var cancelled = false
    private var cancellationReason: CancellationReason?

    public init() {}

    public func cancel(reason: CancellationReason = .cancelled) {
        lock.lock()
        cancelled = true
        if cancellationReason == nil { cancellationReason = reason }
        lock.unlock()
    }

    public var reason: CancellationReason? {
        lock.lock()
        defer { lock.unlock() }
        return cancellationReason
    }

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// Root traversal/session coordinator for enormous source trees. `Indexer`
/// remains the single per-file analysis authority; this type owns only the
/// scale-sensitive orchestration around it:
/// - streaming discovery in bounded batches
/// - disk-backed scan generations instead of a full in-memory seen set
/// - cooperative cancellation
/// - bounded inaccessible-prefix backoff
/// - bounded per-batch similarity invalidation
public final class ScalableIndexSession: @unchecked Sendable {
    public struct Options: Sendable {
        public var batchSize: Int = 512
        public var maxFiles: Int? = nil
        public var maxDepth: Int = 16
        public var excludedPaths: [String] = []
        public var excludedDirectoryNames: Set<String> = OnboardingExclusions.defaultDirectoryNames
        public var enablePersistentEmbeddingWorker = false
        public var updateSimilarity = true
        /// Automatic live reconciliation respects catalog backoff. A manual
        /// cleanup/reauthorization sets this false so inaccessible roots are
        /// retried immediately and fresh failures replace the old state.
        public var respectAccessBackoff = false
        public init() {}
    }

    public enum CompletionReason: String, Sendable, Equatable {
        case completed
        case cancelled
        case paused
        case limited
        case rootUnavailable
    }

    public struct Progress: Sendable, Equatable {
        public let rootPath: String
        public let scanned: Int
        public let processed: Int
        public let lastPath: String
        public let cancelled: Bool
        public let paused: Bool
    }

    public struct Result: Sendable, Equatable {
        public let rootPath: String
        public let scanned: Int
        public let processed: Int
        public let missingMarked: Int
        public let cancelled: Bool
        public let paused: Bool
        public let unreadableDirectories: Int
        public let completion: CompletionReason
    }

    private let broker: SourceBroker
    private let catalog: Catalog
    private let indexer: Indexer
    private let options: Options

    public init(broker: SourceBroker, catalog: Catalog, indexer: Indexer,
                options: Options = Options()) {
        self.broker = broker
        self.catalog = catalog
        self.indexer = indexer
        self.options = options
    }

    @discardableResult
    public func indexRoot(
        _ root: URL,
        cancellation: IndexCancellationToken? = nil,
        onProgress: ((Progress) -> Void)? = nil
    ) throws -> Result {
        let scanGeneration = try catalog.beginRootScanGeneration()
        var scanned = 0
        var processed = 0
        var missingMarked = 0
        var unreadableDirectories = 0
        var rootUnavailable = false
        var unreadablePrefixes = Set<String>()

        func normalizedPrefix(_ path: String) -> String {
            guard path.count > 1, path.hasSuffix("/") else { return path }
            return String(path.dropLast())
        }

        func rememberUnreadablePrefix(_ path: String) {
            // The set is deliberately capped and disposable. Catalog rows are
            // the durable backoff state; this only prevents a failed subtree
            // from being probed once per descendant during this pass.
            guard unreadablePrefixes.count < 1_024 else { return }
            unreadablePrefixes.insert(normalizedPrefix(path))
        }

        let activeBackoff: [String]
        if options.respectAccessBackoff {
            activeBackoff = (try? catalog.activeAccessBackoffEntries())?.map(\.prefix) ?? []
        } else {
            // A user-triggered cleanup or reauthorization is an explicit retry.
            try? catalog.clearAccessBackoff(atOrUnder: root.path)
            activeBackoff = []
        }
        let normalizedRoot = root.path.count > 1 && root.path.hasSuffix("/")
            ? String(root.path.dropLast()) : root.path
        if activeBackoff.contains(where: {
            let normalized = $0.count > 1 && $0.hasSuffix("/")
                ? String($0.dropLast()) : $0
            return normalized == normalizedRoot
        }) {
            // A persisted backoff on the authorized root itself means the
            // lease is not currently usable, not merely that one subtree is
            // noisy. Surface that state to the app instead of silently
            // reporting a successful zero-entry scan.
            rootUnavailable = true
        }
        let effectiveExcludedPrefixes = Array(Set(options.excludedPaths + activeBackoff)).sorted()

        let worker: LocalModelBridge.PersistentWorker? = {
            guard options.enablePersistentEmbeddingWorker,
                  indexer.embeddingProvider is LocalModelEmbeddingProvider,
                  LocalModelBridge.isProvisioned(.clipImage)
                    || LocalModelBridge.isProvisioned(.miniLMText) else { return nil }
            return LocalModelBridge.PersistentWorker()
        }()
        defer { worker?.close() }
        let sessionCatalog = catalog
        // Similarity invalidation is batched across the whole scan: the
        // rebuild loads the entire node+edge graph, so running it once per
        // 512-file batch multiplied that full-graph cost by N/batchSize.
        var pendingSimilarityChanges = Set<String>()
        var pendingSimilarityRemovals = Set<String>()

        let discovered = try SourceBroker.enumerateBatches(
            root: root,
            maxDepth: options.maxDepth,
            excludedPrefixes: effectiveExcludedPrefixes,
            excludedDirectoryNames: options.excludedDirectoryNames,
            maxItems: options.maxFiles,
            batchSize: options.batchSize,
            continuePredicate: { cancellation?.isCancelled != true },
            onUnreadableDirectory: { [sessionCatalog] prefix, reason in
                unreadableDirectories += 1
                rememberUnreadablePrefix(prefix)
                try? sessionCatalog.recordAccessBackoff(prefix: prefix, reason: reason)
            },
            onRootUnavailable: { [sessionCatalog] prefix, reason in
                rootUnavailable = true
                if reason == "permission-denied" {
                    rememberUnreadablePrefix(prefix)
                    try? sessionCatalog.recordAccessBackoff(prefix: prefix, reason: reason)
                }
            }
        ) { [self] batch in
            guard cancellation?.isCancelled != true else { return false }
            var changedIDs = Set<String>()
            var seenPaths: [String] = []
            seenPaths.reserveCapacity(batch.count)

            for item in batch {
                guard cancellation?.isCancelled != true else { break }
                scanned += 1
                seenPaths.append(item.path)
                do {
                    let didProcess = try indexer.indexOneForScan(
                        path: item.path, worker: worker, updateSimilarity: false)
                    if didProcess {
                        processed += 1
                        if let current = try? broker.identity(at: item.path) {
                            changedIDs.insert(FileID.make(identity: current))
                        }
                    }
                } catch {
                    try? catalog.recordError(
                        opaqueRef: FileID.workerError(scanned), stage: "index",
                        message: String(describing: error).prefix(200).description)
                }
                let isPaused = cancellation?.reason == .paused
                onProgress?(Progress(rootPath: root.path, scanned: scanned, processed: processed,
                                     lastPath: (item.path as NSString).lastPathComponent,
                                     cancelled: cancellation?.isCancelled == true,
                                     paused: isPaused))
            }

            // Every discovered path is marked on disk, including unchanged
            // files and files whose current generation could not be analyzed.
            // This prevents an incomplete analysis from masquerading as a
            // filesystem deletion during the later missing sweep.
            try catalog.markRootScanSeen(
                    generation: scanGeneration,
                paths: seenPaths)

            pendingSimilarityChanges.formUnion(changedIDs)
            return cancellation?.isCancelled != true
        }

        // `enumerateBatches` can stop at maxFiles intentionally. An intentional
        // partial scan cannot prove absence, so missing-file reconciliation is
        // performed only after a complete uncapped traversal.
        let hitExplicitLimit = options.maxFiles.map { discovered >= $0 } ?? false
        let cancelled = cancellation?.isCancelled == true
        if !cancelled && !rootUnavailable && !hitExplicitLimit {
            var cursor: String? = nil
            missingSweep: while true {
                if cancellation?.isCancelled == true { break }
                let page = try catalog.unseenRootScanCandidates(
                    generation: scanGeneration,
                    root: root.path,
                    afterPath: cursor,
                    limit: options.batchSize)
                guard !page.isEmpty else { break }

                var removedIDs = Set<String>()
                for candidate in page {
                    cursor = candidate.path
                    if cancellation?.isCancelled == true { break missingSweep }
                    if effectiveExcludedPrefixes.contains(where: {
                        SourceBroker.isPath(candidate.path, under: $0)
                    }) || unreadablePrefixes.contains(where: {
                        SourceBroker.isPath(candidate.path, under: $0)
                    }) { continue }
                    if candidate.path.split(separator: "/").contains(where: {
                        OnboardingExclusions.isExcludedDirectoryName(
                            String($0), configured: options.excludedDirectoryNames)
                    }) { continue }

                    do {
                        _ = try broker.identity(at: candidate.path)
                    } catch BrokerError.statFailed(let error)
                        where error == ENOENT || error == ENOTDIR {
                        try catalog.markMissing(path: candidate.path)
                        missingMarked += 1
                        removedIDs.insert(candidate.id)
                    } catch BrokerError.statFailed(let error)
                        where error == EACCES || error == EPERM {
                        try? catalog.recordAccessBackoff(
                            prefix: candidate.path, reason: "permission-denied")
                        continue
                    } catch {
                        // A symlink refusal or transient filesystem error is
                        // not proof that the source vanished.
                        continue
                    }
                }
                pendingSimilarityRemovals.formUnion(removedIDs)
            }
        }

        // One graph rebuild per scan, after all changes are known.
        if options.updateSimilarity, cancellation?.isCancelled != true,
           !pendingSimilarityChanges.isEmpty || !pendingSimilarityRemovals.isEmpty {
            try? indexer.rebuildSimilarityGraph(
                changedFileIDs: pendingSimilarityChanges,
                removedFileIDs: pendingSimilarityRemovals)
        }

        if cancellation?.isCancelled != true {
            try? catalog.pruneUnusedVirtualCategories()
        }
        let finalCancelled = cancellation?.isCancelled == true
        let completion: CompletionReason
        if rootUnavailable {
            completion = .rootUnavailable
        } else if finalCancelled {
            completion = cancellation?.reason == .paused ? .paused : .cancelled
        } else if hitExplicitLimit {
            completion = .limited
        } else {
            completion = .completed
        }
        // This is one aggregate SQL refresh, not a Swift-side snapshot of file
        // text or vector rows. Partial, cancelled, and unavailable passes are
        // retained with complete == false so project-level answers cannot
        // overclaim coverage while a root needs resume/reauthorization.
        _ = try? catalog.refreshProjectSemanticSummary(
            root: root.path, complete: completion == .completed)
        return Result(rootPath: root.path,
                      scanned: scanned,
                      processed: processed,
                      missingMarked: missingMarked,
                      cancelled: finalCancelled,
                      paused: cancellation?.reason == .paused,
                      unreadableDirectories: unreadableDirectories,
                      completion: completion)
    }
}
