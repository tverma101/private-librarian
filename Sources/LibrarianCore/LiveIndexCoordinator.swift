import Foundation
#if canImport(CoreServices)
import CoreServices
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct LiveRawEvent: Sendable, Equatable {
    public let path: String
    public let flags: UInt32
    public let eventId: UInt64

    public init(path: String, flags: UInt32 = 0, eventId: UInt64 = 0) {
        self.path = path
        self.flags = flags
        self.eventId = eventId
    }

    public static let mustScanSubDirs: UInt32 = 0x00000001
    public static let userDropped: UInt32 = 0x00000002
    public static let kernelDropped: UInt32 = 0x00000004
    public static let historyDone: UInt32 = 0x00000010
    public static let rootChanged: UInt32 = 0x00000020
    public static let mount: UInt32 = 0x00000040
    public static let unmount: UInt32 = 0x00000080
    public static let itemCreated: UInt32 = 0x00000100
    public static let itemRemoved: UInt32 = 0x00000200
    public static let itemRenamed: UInt32 = 0x00000800
    public static let itemModified: UInt32 = 0x00001000
    public static let itemIsDir: UInt32 = 0x00002000
}

public final class LiveCoalescingQueue: @unchecked Sendable {
    public struct CoalescedBatch: Sendable {
        public let paths: [String]
        public let needsFullRescan: Bool
        public let rawEvents: [LiveRawEvent]
    }

    public struct Metrics: Sendable, Equatable {
        public let peakPendingPaths: Int
        public let stormCollapses: Int
    }

    private let lock = NSLock()
    private var pending: [String: LiveRawEvent] = [:]
    private var needsFullRescan = false
    private var peakPendingPathsValue = 0
    private var stormCollapsesValue = 0

    public let debounceInterval: TimeInterval
    public let maxPendingPaths: Int

    public init(debounceInterval: TimeInterval = 0.8, maxPendingPaths: Int = 4_096) {
        self.debounceInterval = debounceInterval
        self.maxPendingPaths = max(1, maxPendingPaths)
    }

    public func ingest(_ events: [LiveRawEvent]) {
        guard !events.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        for event in events {
            if Self.isDroppedEvent(flags: event.flags) {
                needsFullRescan = true
                pending.removeAll(keepingCapacity: false)
                continue
            }

            // Once a storm has collapsed to reconciliation, keeping more
            // individual compiler-output paths only wastes memory.
            if needsFullRescan { continue }

            let key = Self.normalizedPath(event.path)
            if pending[key] == nil && pending.count >= maxPendingPaths {
                stormCollapsesValue += 1
                needsFullRescan = true
                pending.removeAll(keepingCapacity: false)
                continue
            }

            pending[key] = event
            peakPendingPathsValue = max(peakPendingPathsValue, pending.count)
        }
    }

    public static func isDroppedEvent(flags: UInt32) -> Bool {
        let mask = LiveRawEvent.mustScanSubDirs
            | LiveRawEvent.userDropped
            | LiveRawEvent.kernelDropped
            | LiveRawEvent.historyDone
            | LiveRawEvent.rootChanged
        return (flags & mask) != 0
    }

    public static func normalizedPath(_ path: String) -> String {
        if path.count > 1 && path.hasSuffix("/") { return String(path.dropLast()) }
        return path
    }

    public func drain() -> CoalescedBatch? {
        lock.lock()
        defer { lock.unlock() }
        guard !pending.isEmpty || needsFullRescan else { return nil }
        let batch = CoalescedBatch(
            paths: Array(pending.keys).sorted(),
            needsFullRescan: needsFullRescan,
            rawEvents: Array(pending.values))
        pending.removeAll(keepingCapacity: false)
        needsFullRescan = false
        return batch
    }

    public var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count + (needsFullRescan ? 1 : 0)
    }

    public var hasPendingFullRescan: Bool {
        lock.lock()
        defer { lock.unlock() }
        return needsFullRescan
    }

    public var metrics: Metrics {
        lock.lock()
        defer { lock.unlock() }
        return Metrics(peakPendingPaths: peakPendingPathsValue,
                       stormCollapses: stormCollapsesValue)
    }
}

public enum LiveExclusions {
    public static func prefixes(catalogPath: String) -> [String] {
        var output: [String] = []
        let fileManager = FileManager.default
        let directory = (catalogPath as NSString).deletingLastPathComponent

        func add(_ path: String) {
            let normalized = path.count > 1 && path.hasSuffix("/")
                ? String(path.dropLast()) : path
            guard !normalized.isEmpty, !output.contains(normalized) else { return }
            output.append(normalized)
        }

        add(directory)
        for root in LocalModelBridge.modelsRoots() { add(root.path) }
        add((directory as NSString).appendingPathComponent("Models"))
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.path {
            add(caches)
        }
        add(NSTemporaryDirectory())
        return output
    }

    public static func isExcluded(
        path: String,
        prefixes: [String],
        directoryNames: Set<String> = OnboardingExclusions.defaultDirectoryNames
    ) -> Bool {
        let normalized = LiveCoalescingQueue.normalizedPath(path)
        for prefix in prefixes where SourceBroker.isPath(normalized, under: prefix) { return true }
        if OnboardingExclusions.isTransientOrSystemFile(path: normalized) { return true }
        return normalized.split(separator: "/").contains {
            OnboardingExclusions.isExcludedDirectoryName(String($0), configured: directoryNames)
        }
    }
}

public final class LiveIndexCoordinator: @unchecked Sendable {
    public struct Options: Sendable {
        public var debounceInterval: TimeInterval = 0.8
        public var maxCoalescedPaths: Int = 2_000
        public var maxPendingPaths: Int = 4_096
        /// Minimum spacing between expensive whole-root reconciliations. A
        /// compiler storm inside this window collapses to one deferred scan.
        public var reconciliationCooldown: TimeInterval = 5.0
        public var excludedPaths: [String] = []
        public var excludedDirectoryNames: Set<String> = OnboardingExclusions.defaultDirectoryNames
        public init() {}
    }

    public struct Metrics: Sendable, Equatable {
        public let peakPendingPaths: Int
        public let stormCollapses: Int
        public let fullReconciliations: Int
    }

    private let catalog: Catalog
    private let indexer: Indexer
    private let broker: SourceBroker
    private let scheduler: Scheduler
    private let options: Options
    private let queue: LiveCoalescingQueue

    // FSEvent delivery and debounce must stay responsive even while an index
    // pass is expensive. File-system intake therefore never shares the serial
    // queue that performs indexing/reconciliation work.
    private let eventQueue = DispatchQueue(label: "librarian.live.events", qos: .utility)
    private let workQueue = DispatchQueue(label: "librarian.live.work", qos: .utility)
    private let lock = NSLock()

    private var roots: [URL]
    private var exclusionPrefixes: [String]
    private var isRunning = false
    private var debounceWorkItem: DispatchWorkItem?
    private var deferredRescanWorkItem: DispatchWorkItem?
    private var lastEventId: UInt64 = 0
    private var lastFullRescanTime: TimeInterval?
    private var fullReconciliationsValue = 0

    public var testIndexOneHandler: ((String) throws -> Bool)?
    public var testMarkMissingHandler: ((String) throws -> Void)?
    public var testFullRescanHandler: (() throws -> Void)?
    public var onStateChange: (() -> Void)?

#if canImport(CoreServices)
    private var streams: [FSEventStreamRef] = []
#endif
    private var wakeObserver: NSObjectProtocol?

    public init(catalog: Catalog, indexer: Indexer, broker: SourceBroker,
                scheduler: Scheduler, roots: [URL], options: Options = Options()) {
        self.catalog = catalog
        self.indexer = indexer
        self.broker = broker
        self.scheduler = scheduler
        self.roots = roots
        self.options = options
        self.queue = LiveCoalescingQueue(
            debounceInterval: options.debounceInterval,
            maxPendingPaths: options.maxPendingPaths)
        self.exclusionPrefixes = LiveExclusions.prefixes(catalogPath: catalog.path)
        self.exclusionPrefixes.append(contentsOf: options.excludedPaths)
    }

    deinit { stop() }

    public func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }
        isRunning = true
        let snapshot = roots
        lock.unlock()

        var exclusions = LiveExclusions.prefixes(catalogPath: catalog.path)
        exclusions.append(contentsOf: options.excludedPaths)
        lock.lock()
        exclusionPrefixes = exclusions
        lock.unlock()

#if canImport(CoreServices)
        startStreams(for: snapshot)
#endif
        observeWake()
    }

    public func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        deferredRescanWorkItem?.cancel()
        deferredRescanWorkItem = nil
        lock.unlock()

#if canImport(CoreServices)
        for stream in streams {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        streams.removeAll()
#endif
        if let observer = wakeObserver {
#if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
#else
            NotificationCenter.default.removeObserver(observer)
#endif
            wakeObserver = nil
        }
    }

    public func addRoot(_ url: URL) {
        lock.lock()
        let alreadyPresent = roots.contains(where: { $0.path == url.path })
        if !alreadyPresent { roots.append(url) }
        let running = isRunning
        lock.unlock()
        guard !alreadyPresent else { return }
#if canImport(CoreServices)
        if running { startStreams(for: [url]) }
#endif
    }

    public func removeRoot(_ url: URL) {
        lock.lock()
        roots.removeAll { $0.path == url.path }
        let running = isRunning
        lock.unlock()
#if canImport(CoreServices)
        if running {
            for stream in streams {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            streams.removeAll()
            lock.lock()
            let snapshot = roots
            lock.unlock()
            if !snapshot.isEmpty { startStreams(for: snapshot) }
        }
#endif
    }

    public var currentRoots: [URL] {
        lock.lock(); defer { lock.unlock() }
        return roots
    }

    public var running: Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    public var pendingCount: Int { queue.pendingCount }

    public var liveMetrics: Metrics {
        let queueMetrics = queue.metrics
        lock.lock()
        let reconciliations = fullReconciliationsValue
        lock.unlock()
        return Metrics(peakPendingPaths: queueMetrics.peakPendingPaths,
                       stormCollapses: queueMetrics.stormCollapses,
                       fullReconciliations: reconciliations)
    }

    private func isUnderWatchedRoot(_ path: String) -> Bool {
        let normalized = LiveCoalescingQueue.normalizedPath(path)
        lock.lock()
        let snapshot = roots
        lock.unlock()
        for root in snapshot {
            let rootPath = LiveCoalescingQueue.normalizedPath(root.path)
            if SourceBroker.isPath(normalized, under: rootPath) { return true }
        }
        return false
    }

    public func ingest(events: [LiveRawEvent]) {
        guard !events.isEmpty else { return }
        if let maximum = events.map(\.eventId).max() {
            lock.lock()
            if maximum > lastEventId { lastEventId = maximum }
            lock.unlock()
        }

        lock.lock()
        let exclusions = exclusionPrefixes
        lock.unlock()
        let filtered = events.filter {
            isUnderWatchedRoot($0.path)
                && !LiveExclusions.isExcluded(path: $0.path, prefixes: exclusions,
                                              directoryNames: options.excludedDirectoryNames)
        }
        let hasDrop = events.contains { LiveCoalescingQueue.isDroppedEvent(flags: $0.flags) }
        if filtered.isEmpty && !hasDrop { return }

        var toIngest = filtered
        if hasDrop && filtered.isEmpty {
            toIngest = [LiveRawEvent(path: "/", flags: LiveRawEvent.mustScanSubDirs,
                                     eventId: lastEventId)]
        }
        if hasDrop && !toIngest.contains(where: { LiveCoalescingQueue.isDroppedEvent(flags: $0.flags) }) {
            toIngest.append(LiveRawEvent(path: "/", flags: LiveRawEvent.mustScanSubDirs,
                                         eventId: lastEventId))
        }
        queue.ingest(toIngest)
        scheduleDebounce()
        onStateChange?()
    }

    public func simulateFileChange(at path: String, flags: UInt32 = LiveRawEvent.itemModified) {
        ingest(events: [LiveRawEvent(path: path, flags: flags, eventId: nextEventID())])
    }

    public func handleDidWake() {
        lock.lock()
        let running = isRunning
        lock.unlock()
        guard running else { return }
        queue.ingest([LiveRawEvent(path: "/", flags: LiveRawEvent.mustScanSubDirs,
                                   eventId: nextEventID())])
        scheduleDebounce(immediate: true)
    }

    private func nextEventID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastEventId &+= 1
        return lastEventId
    }

    private func scheduleDebounce(immediate: Bool = false) {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        debounceWorkItem?.cancel()
        let delay = immediate ? 0.05 : options.debounceInterval
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workQueue.async { [weak self] in
                _ = self?.drainAndProcess()
            }
        }
        debounceWorkItem = item
        lock.unlock()
        eventQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    @discardableResult
    public func flushForTesting() -> LiveCoalescingQueue.CoalescedBatch? {
        lock.lock()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        lock.unlock()
        return drainAndProcessSync()
    }

    @discardableResult
    private func drainAndProcess() -> LiveCoalescingQueue.CoalescedBatch? {
        drainAndProcessSync()
    }

    @discardableResult
    private func drainAndProcessSync() -> LiveCoalescingQueue.CoalescedBatch? {
        guard let batch = queue.drain() else { return nil }
        process(batch: batch)
        return batch
    }

    private func process(batch: LiveCoalescingQueue.CoalescedBatch) {
        if batch.needsFullRescan || batch.paths.count > options.maxCoalescedPaths {
            requestFullRescan(reason: batch.needsFullRescan ? "dropped-events" : "storm-overflow")
            onStateChange?()
            return
        }

        lock.lock()
        let exclusions = exclusionPrefixes
        lock.unlock()
        let paths = batch.paths.filter {
            isUnderWatchedRoot($0)
                && !LiveExclusions.isExcluded(path: $0, prefixes: exclusions,
                                              directoryNames: options.excludedDirectoryNames)
        }
        guard !paths.isEmpty else { onStateChange?(); return }

        var changedIDs = Set<String>()
        var removedIDs = Set<String>()
        for path in paths {
            do {
                let delta = try processSinglePath(path)
                if let changed = delta.changedID { changedIDs.insert(changed) }
                if let removed = delta.removedID { removedIDs.insert(removed) }
            } catch {
                try? catalog.recordError(
                    opaqueRef: FileID.workerError(0), stage: "live-index",
                    message: String(describing: error).prefix(200).description)
            }
        }
        if !changedIDs.isEmpty || !removedIDs.isEmpty {
            try? indexer.rebuildSimilarityGraph(changedFileIDs: changedIDs,
                                                removedFileIDs: removedIDs)
        }
        onStateChange?()
    }

    private func automaticRootSession() -> ScalableIndexSession {
        var sessionOptions = ScalableIndexSession.Options()
        sessionOptions.excludedPaths = options.excludedPaths
        sessionOptions.excludedDirectoryNames = options.excludedDirectoryNames
        sessionOptions.respectAccessBackoff = true
        return ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: sessionOptions)
    }

    private func processSinglePath(_ path: String) throws -> (changedID: String?, removedID: String?) {
        let previousID = try? catalog.fileID(forPath: path)
        do {
            _ = try broker.identity(at: path)
        } catch BrokerError.statFailed(let error) where error == ENOENT || error == ENOTDIR {
            try markMissing(atOrUnder: path)
            return (nil, previousID ?? nil)
        } catch {
            // Permission failures, symlink refusals, and transient filesystem
            // errors are not proof that a source vanished.
            return (nil, nil)
        }

        let indexed: Bool
        if let handler = testIndexOneHandler {
            indexed = try handler(path)
        } else {
            if broker.isDirectory(at: path) {
                _ = try automaticRootSession().indexRoot(URL(fileURLWithPath: path))
                return (nil, nil)
            }
            indexed = (try? indexer.indexOne(path: path, updateSimilarity: false)) ?? false
        }
        guard indexed, let identity = try? broker.identity(at: path) else { return (nil, nil) }
        return (FileID.make(identity: identity), nil)
    }

    private func markMissing(atOrUnder path: String) throws {
        if let handler = testMarkMissingHandler {
            try handler(path)
            return
        }
        try? catalog.markMissing(path: path)
        for row in (try? catalog.allFiles()) ?? []
            where row.status != "missing" && SourceBroker.isPath(row.path, under: path) {
            try? catalog.markMissing(path: row.path)
        }
    }

    /// Expensive whole-root reconciliation is rate-limited independently from
    /// event intake. Repeated dropped-event/compiler storms within the cooldown
    /// schedule one deferred scan instead of a tight rescan loop.
    private func requestFullRescan(reason: String) {
        let now = Date.timeIntervalSinceReferenceDate
        lock.lock()
        if let last = lastFullRescanTime {
            let elapsed = now - last
            let remaining = options.reconciliationCooldown - elapsed
            if remaining > 0 {
                if deferredRescanWorkItem == nil {
                    let item = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.workQueue.async { [weak self] in
                            self?.runFullRescan(reason: "settled-\(reason)")
                        }
                    }
                    deferredRescanWorkItem = item
                    lock.unlock()
                    eventQueue.asyncAfter(deadline: .now() + remaining, execute: item)
                    return
                }
                lock.unlock()
                return
            }
        }
        lastFullRescanTime = now
        fullReconciliationsValue += 1
        lock.unlock()
        performFullRescan(reason: reason)
    }

    private func runFullRescan(reason: String) {
        lock.lock()
        deferredRescanWorkItem = nil
        lastFullRescanTime = Date.timeIntervalSinceReferenceDate
        fullReconciliationsValue += 1
        lock.unlock()
        performFullRescan(reason: reason)
    }

    private func performFullRescan(reason: String) {
        if let handler = testFullRescanHandler {
            try? handler()
            return
        }
        try? catalog.recordError(opaqueRef: "live-rescan", stage: "live-reconcile",
                                 message: "full rescan: \(reason)")
        lock.lock()
        let snapshot = roots
        lock.unlock()
        for root in snapshot where FileManager.default.fileExists(atPath: root.path) {
            _ = try? automaticRootSession().indexRoot(root)
        }
    }

    private func observeWake() {
#if canImport(AppKit)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidWake() }
#else
        wakeObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("LiveIndexCoordinatorDidWake"), object: nil, queue: .main
        ) { [weak self] _ in self?.handleDidWake() }
#endif
    }

#if canImport(CoreServices)
    private func startStreams(for urls: [URL]) {
        for url in urls {
            let path = url.path as NSString
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil, release: nil, copyDescription: nil)
            let flags: FSEventStreamCreateFlags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes)
            let latency: CFTimeInterval = options.debounceInterval
            let callback: FSEventStreamCallback = {
                _, info, numEvents, eventPaths, eventFlags, eventIds in
                guard let info else { return }
                let coordinator = Unmanaged<LiveIndexCoordinator>
                    .fromOpaque(info).takeUnretainedValue()
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                let count = min(numEvents, CFArrayGetCount(paths))
                var events: [LiveRawEvent] = []
                events.reserveCapacity(count)
                for index in 0..<count {
                    guard let value = CFArrayGetValueAtIndex(paths, index) else { continue }
                    let object = Unmanaged<AnyObject>.fromOpaque(value).takeUnretainedValue()
                    guard let eventPath = object as? String else { continue }
                    events.append(LiveRawEvent(path: eventPath,
                                               flags: eventFlags[index],
                                               eventId: eventIds[index]))
                }
                coordinator.ingest(events: events)
            }
            let watched = [path] as CFArray
            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault, callback, &context, watched,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
            else { continue }
            FSEventStreamSetDispatchQueue(stream, eventQueue)
            FSEventStreamStart(stream)
            streams.append(stream)
        }
    }
#endif
}
