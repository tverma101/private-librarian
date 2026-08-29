#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}\n--- OLD ---\n{old[:500]}")
    p.write_text(text.replace(old, new, 1))


# ---------------------------------------------------------------------------
# Indexer: ASR provider/model invalidation + explicit retryable failure state.
# ---------------------------------------------------------------------------
replace_once(
    "Sources/LibrarianCore/Indexer.swift",
    '''        self.processingVersion = Self.makeProcessingVersion(
            options: options, providerID: self.embeddingProvider.providerID,
            learnedRules: learnedRules)
''',
    '''        self.processingVersion = Self.makeProcessingVersion(
            options: options, providerID: self.embeddingProvider.providerID,
            asrProviderIdentity: TranscriptionProviderState.processingIdentity(transcriptionProvider),
            learnedRules: learnedRules)
''')

replace_once(
    "Sources/LibrarianCore/Indexer.swift",
    '''    private static func makeProcessingVersion(options: Options, providerID: String? = nil,
                                              learnedRules: [LearnedRule] = []) -> String {
''',
    '''    private static func makeProcessingVersion(options: Options, providerID: String? = nil,
                                              asrProviderIdentity: String? = nil,
                                              learnedRules: [LearnedRule] = []) -> String {
''')

replace_once(
    "Sources/LibrarianCore/Indexer.swift",
    '''        // ASR participation must invalidate incremental state: flipping the
        // opt-in forces one honest re-index instead of serving stale derived
        // media. (Provider identity is not encoded here — swapping providers
        // under the same opt-in state intentionally reuses the existing
        // transcript until content changes; encode providerID here if that
        // policy ever changes.)
        parts.append("asr:\\(options.enableLocalASR ? \"on\" : \"off\")")
''',
    '''        // ASR output is generation-scoped just like embeddings. Enabling
        // ASR or changing the provider/binary/model identity forces exactly
        // one honest re-index; the same identity returns to zero-work skips.
        if options.enableLocalASR {
            parts.append("asr:on,provider:\\(asrProviderIdentity ?? \"unknown\")")
        } else {
            parts.append("asr:off")
        }
''')

replace_once(
    "Sources/LibrarianCore/Indexer.swift",
    '''        // Audio/speech gating: probe -> gate -> transcribe (provider returns nil when disabled)
        var stagedTranscript: (provider: String, segments: [TranscriptSegment])? = nil
        if ident.kind == .audio || ident.kind == .video {
            let ext = (ident.path as NSString).pathExtension
            // Complete broker snapshot for probe — never reopens path inside AudioProbe.
            // A read failure here is NOT evidence that speech vanished; it must
            // not purge a valid transcript below, and it must not be recorded
            // as indexed either (that would end incremental retries).
            guard let mBytes = try? broker.completeSnapshot(ident.path, maxBytes: options.maxMediaSnapshotBytes),
                  !mBytes.isEmpty else {
                try catalog.setStatus(fileID: id, status: "pending")
                return true
            }
            let decision = AudioProbe.probe(bytes: mBytes, fileExtension: ext.isEmpty ? nil : ext, tagHint: nil)
            if decision.shouldTranscribe, options.enableLocalASR {
                // Only run when not Disabled — cheap check before any PCM work
                if !(transcriptionProvider is DisabledSpeechTranscriptionProvider) {
                    var pcmChunks: [PCMChunk] = []
                    do {
                        recordWork { $0.decodeCalls += 1 }
                        try scheduler.perform(as: .medium) {
                            try pcmDecoder.decode(snapshot: mBytes) { chunk in
                                pcmChunks.append(chunk)
                            }
                        }
                    } catch {
                        // Decode failure must never abort indexing (resilience),
                        // but it is recorded — and partial PCM from a decoder
                        // that threw mid-stream must not be transcribed either:
                        // a prefix of a corrupt file is still a lie.
                        pcmChunks = []
                        try? catalog.recordError(opaqueRef: id, stage: "media-decode",
                                                 message: String(describing: error).prefix(200).description)
                    }
                    if !pcmChunks.isEmpty,
                       let segs = scheduler.perform(as: .heavy, { transcriptionProvider.transcribe(pcmChunks) }),
                       !segs.isEmpty {
                        stagedTranscript = (transcriptionProvider.providerID, segs)
                    }
                }
            }
        }
''',
    '''        // Audio/speech gating: probe -> gate -> explicit transcription outcome.
        var stagedTranscript: (provider: String, segments: [TranscriptSegment])? = nil
        var transcriptionFailure: String? = nil
        if ident.kind == .audio || ident.kind == .video {
            let ext = (ident.path as NSString).pathExtension
            // Complete broker snapshot for probe — never reopens path inside AudioProbe.
            // A read failure here is NOT evidence that speech vanished; it must
            // not purge a valid transcript below, and it must not be recorded
            // as indexed either (that would end incremental retries).
            guard let mBytes = try? broker.completeSnapshot(ident.path, maxBytes: options.maxMediaSnapshotBytes),
                  !mBytes.isEmpty else {
                try catalog.setStatus(fileID: id, status: "pending")
                return true
            }
            let decision = AudioProbe.probe(bytes: mBytes, fileExtension: ext.isEmpty ? nil : ext, tagHint: nil)
            if decision.shouldTranscribe, options.enableLocalASR {
                // Only run when not Disabled — cheap check before any PCM work.
                if !(transcriptionProvider is DisabledSpeechTranscriptionProvider) {
                    var pcmChunks: [PCMChunk] = []
                    do {
                        recordWork { $0.decodeCalls += 1 }
                        try scheduler.perform(as: .medium) {
                            try pcmDecoder.decode(snapshot: mBytes) { chunk in
                                pcmChunks.append(chunk)
                            }
                        }
                    } catch {
                        // A definitive decode failure means this readable
                        // generation produced no transcript; commit-time
                        // generation cleanup below will remove stale speech.
                        pcmChunks = []
                        try? catalog.recordError(opaqueRef: id, stage: "media-decode",
                                                 message: String(describing: error).prefix(200).description)
                    }
                    if !pcmChunks.isEmpty {
                        switch scheduler.perform(as: .heavy, {
                            TranscriptionProviderState.transcribe(transcriptionProvider, chunks: pcmChunks)
                        }) {
                        case .success(let segments) where !segments.isEmpty:
                            stagedTranscript = (transcriptionProvider.providerID, segments)
                        case .success, .noTranscript:
                            stagedTranscript = nil
                        case .failure(let message):
                            transcriptionFailure = message
                        }
                    }
                }
            }
        }

        // A provider execution/parsing failure is not a successful empty
        // transcript. Keep the new file generation pending, retain the old
        // derived rows for retry bookkeeping, and rely on status-filtered
        // search to keep that old transcript out of current results.
        if let transcriptionFailure {
            guard let now = try? broker.identity(at: path), ident.stillMatches(now) else {
                try catalog.setStatus(fileID: id, status: "changed-during-index")
                return true
            }
            try? catalog.recordError(opaqueRef: id, stage: "media-asr",
                                     message: transcriptionFailure.prefix(200).description)
            try catalog.setStatus(fileID: id, status: "pending")
            return true
        }
''')

# ---------------------------------------------------------------------------
# SwiftUI app: fail-closed bookmarks, live lease lifetime, Swift concurrency,
# and an actual opt-in local transcription setting.
# ---------------------------------------------------------------------------
replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    struct PreviewRequest: Sendable, Equatable {
        let path: String
        let bookmarkData: Data?
    }
''',
    '''    struct PreviewRequest: Sendable, Equatable {
        let path: String
        let sourceRoot: String
        let bookmarkData: Data?
    }
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    @Published private(set) var liveIndexRunning = false
    @Published private(set) var livePendingEvents = 0
    @Published var localEmbeddingsEnabled: Bool {
''',
    '''    @Published private(set) var liveIndexRunning = false
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
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    var isTier2Provisioned: Bool {
        CoreMLMobileCLIPProvider.isAvailable
            || LocalModelBridge.isProvisioned(.clipImage)
            || LocalModelBridge.isProvisioned(.miniLMText)
    }

    private var catalog: Catalog?
    private var bookmarkDataByPath: [String: Data] = [:]
    private var liveCoordinator: LiveIndexCoordinator?
''',
    '''    var isTier2Provisioned: Bool {
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
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    init() {
        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
''',
    '''    init() {
        self.localTranscriptionEnabled = UserDefaults.standard.bool(forKey: AppLocalTranscription.enabledDefaultsKey)
            && AppLocalTranscription.isAvailable
        self.localEmbeddingsEnabled = UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''        bookmarkDataByPath.removeValue(forKey: source.path)
        pausedPaths.remove(source.path)
''',
    '''        bookmarkDataByPath.removeValue(forKey: source.path)
        pausedPaths.remove(source.path)
        sourcesNeedingReauthorization.remove(source.path)
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''            self.bookmarkDataByPath.removeValue(forKey: source.path)
            self.bookmarkDataByPath[url.path] = data
''',
    '''            self.bookmarkDataByPath.removeValue(forKey: source.path)
            self.bookmarkDataByPath[url.path] = data
            self.sourcesNeedingReauthorization.remove(source.path)
            self.sourcesNeedingReauthorization.remove(url.path)
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    /// Resolve a stored read-only security-scoped bookmark and run `body`
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
''',
    '''    func needsReauthorization(_ source: SourceFolder) -> Bool {
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
            log("folder needs reauthorization: \\(source.path)")
            return nil
        }
    }
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    private func makeIndexer() -> Indexer? {
        guard let catalog else { return nil }
        var options = Indexer.Options()
        options.enableLocalEmbeddings = localEmbeddingsEnabled
        options.embeddingProviderKind = CoreMLMobileCLIPProvider.isAvailable ? "coreml-mobileclip" : nil
        options.excludedPaths = effectiveExcludedPaths
        return Indexer(broker: SourceBroker(), catalog: catalog,
                       scheduler: Scheduler(), options: options)
    }
''',
    '''    private func makeIndexer() -> Indexer? {
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
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    private func restartLiveCoordinator() {
        liveCoordinator?.stop()
        liveCoordinator = nil
        liveIndexRunning = false
        livePendingEvents = 0
        guard let catalog, !sources.isEmpty else { return }
        var options = LiveIndexCoordinator.Options()
        options.excludedPaths = effectiveExcludedPaths
        let broker = SourceBroker()
        guard let indexer = makeIndexer() else { return }
        let roots = sources.filter { !pausedPaths.contains($0.path) }
            .map { URL(fileURLWithPath: $0.path) }
        let coordinator = LiveIndexCoordinator(catalog: catalog, indexer: indexer,
                                               broker: broker, scheduler: Scheduler(),
                                               roots: roots, options: options)
        coordinator.onStateChange = { [weak self, weak coordinator] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.livePendingEvents = coordinator?.pendingCount ?? 0
                self.refreshDashboard()
            }
        }
        liveCoordinator = coordinator
        coordinator.start()
        liveIndexRunning = coordinator.running
    }
''',
    '''    private func restartLiveCoordinator() {
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
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    func startIndexing() {
        guard let indexer = makeIndexer(), !isIndexing else { return }
        isIndexing = true
        let sourcesToIndex = sources.filter { !pausedPaths.contains($0.path) }
        let bookmarksToUse = bookmarkDataByPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for src in sourcesToIndex {
                _ = Self.accessSource(src, bookmarkData: bookmarksToUse[src.path]) { url in
                    _ = try? indexer.indexRoot(url) { p in
                        DispatchQueue.main.async {
                            self?.log("indexing… \\(p.processed)/\\(p.total)")
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
''',
    '''    func startIndexing() {
        guard let indexer = makeIndexer(), !isIndexing else { return }
        isIndexing = true
        let jobs: [(SourceFolder, SecurityScopedBookmarkLease)] = sources
            .filter { !pausedPaths.contains($0.path) }
            .compactMap { source in sourceLease(for: source).map { (source, $0) } }
        guard !jobs.isEmpty else {
            isIndexing = false
            log("no authorized source folders available for indexing")
            return
        }

        Task.detached(priority: .userInitiated) { [weak self, jobs, indexer] in
            for (_, lease) in jobs {
                _ = try? indexer.indexRoot(lease.url) { progress in
                    Task { @MainActor [weak self] in
                        self?.log("indexing… \\(progress.processed)/\\(progress.total)")
                    }
                }
            }
            await MainActor.run { [weak self] in
                self?.isIndexing = false
                self?.log("indexing complete")
                self?.refreshDashboard()
            }
        }
    }
''')

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    func previewRequest(for id: String) -> PreviewRequest? {
        guard let catalog,
              let row = try? catalog.fileRow(id: id) else { return nil }
        return PreviewRequest(path: row.path, bookmarkData: bookmarkDataByPath[row.path])
    }

    /// Load a bounded, read-only image snapshot for the similarity UI. This is
    /// intentionally nonisolated so the caller can perform the broker read
    /// away from the main actor; the source path is never passed to a model.
    nonisolated static func previewData(_ request: PreviewRequest) -> Data? {
        let source = SourceFolder(id: UUID(), path: request.path)
        do {
            return try accessSource(source, bookmarkData: request.bookmarkData) { url in
                try SourceBroker().completeSnapshot(
                    url.path, maxBytes: 16 * 1024 * 1024)
            }
        } catch {
            return nil
        }
    }
''',
    '''    func previewRequest(for id: String) -> PreviewRequest? {
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
''')

# ---------------------------------------------------------------------------
# SwiftUI: show reauthorization state and expose the opt-in ASR setting.
# ---------------------------------------------------------------------------
replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''                                Text(source.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if model.isPaused(source) {
                                    Text("Paused — originals remain untouched")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
''',
    '''                                Text(source.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if model.needsReauthorization(source) {
                                    Text("Needs reauthorization — indexing is paused for this folder")
                                        .font(.caption2).foregroundStyle(.orange)
                                } else if model.isPaused(source) {
                                    Text("Paused — originals remain untouched")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
''')

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''                    Toggle("Local embeddings", isOn: $model.localEmbeddingsEnabled)
                        .help(model.isTier2Provisioned ? "On-device only — no network" : "Provision Models/ first")
                        .disabled(!model.isTier2Provisioned)
                    Picker("Search", selection: $model.searchMode) {
''',
    '''                    Toggle("Local embeddings", isOn: $model.localEmbeddingsEnabled)
                        .help(model.isTier2Provisioned ? "On-device only — no network" : "Provision Models/ first")
                        .disabled(!model.isTier2Provisioned)
                    Toggle("Local transcription", isOn: $model.localTranscriptionEnabled)
                        .help("Opt-in whisper.cpp transcription. Nothing is downloaded automatically.")
                        .disabled(!model.isLocalTranscriptionAvailable)
                    Text(model.localTranscriptionStatus)
                        .font(.caption2)
                        .foregroundStyle(model.isLocalTranscriptionAvailable ? .secondary : .orange)
                    Picker("Search", selection: $model.searchMode) {
''')

print("final release patch applied")
