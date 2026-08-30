import Foundation

/// Cooperative cancellation shared by the UI and a long root-index session.
/// Cancellation is checked between discovered files and before missing-file
/// reconciliation. A currently executing atomic per-file commit is never torn.
public final class IndexCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
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

    public struct Progress: Sendable, Equatable {
        public let scanned: Int
        public let processed: Int
        public let lastPath: String
    }

    public struct Result: Sendable, Equatable {
        public let scanned: Int
        public let processed: Int
        public let missingMarked: Int
        public let cancelled: Bool
        public let unreadableDirectories: Int
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

        let activeBackoff: [String]
        if options.respectAccessBackoff {
            activeBackoff = (try? catalog.activeAccessBackoffEntries())?.map(\.prefix) ?? []
        } else {
            // A user-triggered cleanup or reauthorization is an explicit retry.
            try? catalog.clearAccessBackoff(atOrUnder: root.path)
            activeBackoff = []
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

        let discovered = try SourceBroker.enumerateBatches(
            root: root,
            maxDepth: options.maxDepth,
            excludedPrefixes: effectiveExcludedPrefixes,
            excludedDirectoryNames: options.excludedDirectoryNames,
            maxItems: options.maxFiles,
            batchSize: options.batchSize,
            onUnreadableDirectory: { [catalog] prefix, reason in
                unreadableDirectories += 1
                try? catalog.recordAccessBackoff(prefix: prefix, reason: reason)
            }
        ) { [self] batch in
            guard cancellation?.isCancelled != true else { return false }
            var changedIDs = Set<String>()

            for item in batch {
                guard cancellation?.isCancelled != true else { break }
                scanned += 1
                do {
                    let didProcess = try indexer.indexOne(
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
                onProgress?(Progress(scanned: scanned, processed: processed,
                                     lastPath: (item.path as NSString).lastPathComponent))
            }

            // Every discovered path is marked on disk, including unchanged
            // files and files whose current generation could not be analyzed.
            // This prevents an incomplete analysis from masquerading as a
            // filesystem deletion during the later missing sweep.
            try catalog.markRootScanSeen(
                generation: scanGeneration,
                paths: batch.map(\.path))

            if options.updateSimilarity, !changedIDs.isEmpty,
               cancellation?.isCancelled != true {
                try? indexer.rebuildSimilarityGraph(changedFileIDs: changedIDs)
            }
            return cancellation?.isCancelled != true
        }

        // `enumerateBatches` can stop at maxFiles intentionally. An intentional
        // partial scan cannot prove absence, so missing-file reconciliation is
        // performed only after a complete uncapped traversal.
        let hitExplicitLimit = options.maxFiles.map { discovered >= $0 } ?? false
        let cancelled = cancellation?.isCancelled == true
        if !cancelled && !hitExplicitLimit {
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
                if options.updateSimilarity, !removedIDs.isEmpty,
                   cancellation?.isCancelled != true {
                    try? indexer.rebuildSimilarityGraph(removedFileIDs: removedIDs)
                }
            }
        }

        if cancellation?.isCancelled != true {
            try? catalog.pruneUnusedVirtualCategories()
        }
        return Result(scanned: scanned,
                      processed: processed,
                      missingMarked: missingMarked,
                      cancelled: cancellation?.isCancelled == true,
                      unreadableDirectories: unreadableDirectories)
    }
}
