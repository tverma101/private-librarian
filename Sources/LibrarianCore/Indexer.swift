import Foundation

/// Deterministic indexing pipeline (plan §32):
///   event → deterministic queue → extractor → classifier → catalog update.
/// No autonomous agent, no watchers that write, no LLM in the loop for v1.
///
/// Race safety (plan §21): identity is captured before processing and re-stat'd
/// immediately before final success; a changed file is marked for retry.
public final class Indexer: @unchecked Sendable {

    public struct Options: Sendable {
        public var maxReadBytes: Int64 = 8 * 1024 * 1024
        public var hashCandidatesOnly = true
        public var maxFiles: Int? = nil
        /// Tier-2 local embeddings (CLIP image + MiniLM text) — still 100% offline.
        /// Default OFF so Vision (zero-download) remains the baseline; enabling
        /// requires `Models/` provisioned and `scripts/embed.py` deps. When off,
        /// no subprocess is ever spawned. Set true for opt-in higher recall.
        public var enableLocalEmbeddings = false
        public var enableOCR = true
        /// Explicit opt-in for decode/ASR. The default remains metadata-only.
        public var enableLocalASR = false
        /// Complete container snapshot ceiling for probe/video APIs that need
        /// random access. Oversize media is analyzed no further.
        public var maxMediaSnapshotBytes: Int64 = 256 * 1024 * 1024
        public var embeddingProviderKind: String? = nil
        /// Absolute source prefixes that are intentionally outside this scan.
        /// Exclusions affect enumeration and missing-file reconciliation but
        /// never delete or mutate existing catalog rows.
        public var excludedPaths: [String] = []
        /// Smart onboarding exclusions are basename rules, so a nested
        /// node_modules/.git/build tree is skipped without discovering it
        /// first or maintaining a user-specific prefix list.
        public var excludedDirectoryNames: Set<String> = OnboardingExclusions.defaultDirectoryNames
        public init() {}
    }

    public struct Progress: Sendable {
        /// Number of discovered entries scanned, including unchanged skips.
        public let processed: Int
        public let total: Int
        public let lastPath: String
    }

    public struct WorkMetrics: Sendable, Equatable {
        public var visionCalls: Int
        public var ocrCalls: Int
        public var clipCalls: Int
        public var textEmbedCalls: Int
        public var decodeCalls: Int

        public init(visionCalls: Int = 0, ocrCalls: Int = 0,
                    clipCalls: Int = 0, textEmbedCalls: Int = 0,
                    decodeCalls: Int = 0) {
            self.visionCalls = visionCalls
            self.ocrCalls = ocrCalls
            self.clipCalls = clipCalls
            self.textEmbedCalls = textEmbedCalls
            self.decodeCalls = decodeCalls
        }
    }

    public struct SimilarityMetrics: Sendable, Equatable {
        public let seconds: Double
        public let changedNodes: Int
        public let edges: Int
        public let clusters: Int

        public init(seconds: Double = 0, changedNodes: Int = 0,
                    edges: Int = 0, clusters: Int = 0) {
            self.seconds = seconds
            self.changedNodes = changedNodes
            self.edges = edges
            self.clusters = clusters
        }
    }

    private let broker: SourceBroker
    private let catalog: Catalog
    private let scheduler: Scheduler
    private let evidence: EvidenceExtractor
    private let classifier = RuleBasedClassifier()
    private let visionAnalyzer = VisionImageAnalyzer()
    private let visionOCR = VisionOCR()
    private let similarityClustering = SimilarityClustering()
    private let options: Options
    private let processingVersion: String
    /// Swappable ASR provider — defaults to Disabled (no transcription until benchmarked).
    private let transcriptionProvider: any SpeechTranscriptionProvider
    /// Swappable decoder — defaults to the broker-owned PCM decoder.
    private let pcmDecoder: any PCMDecoding
    public let embeddingProvider: any EmbeddingProvider
    private let embeddingAvailable: Bool
    private let metricsLock = NSLock()
    private var metrics = WorkMetrics()
    private var lastSimilarityMetrics = SimilarityMetrics()

    public var workMetrics: WorkMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return metrics
    }

    public func resetWorkMetrics() {
        metricsLock.lock()
        metrics = WorkMetrics()
        metricsLock.unlock()
    }

    public var similarityMetrics: SimilarityMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return lastSimilarityMetrics
    }

    private func recordWork(_ update: (inout WorkMetrics) -> Void) {
        metricsLock.lock()
        update(&metrics)
        metricsLock.unlock()
    }

    public init(broker: SourceBroker, catalog: Catalog, scheduler: Scheduler,
                options: Options = .init(),
                transcriptionProvider: any SpeechTranscriptionProvider = DisabledSpeechTranscriptionProvider(),
                pcmDecoder: (any PCMDecoding)? = nil,
                embeddingProvider: (any EmbeddingProvider)? = nil) {
        self.broker = broker
        self.catalog = catalog
        self.scheduler = scheduler
        self.options = options
        self.evidence = EvidenceExtractor(broker: broker)
        if let p = embeddingProvider { self.embeddingProvider = p }
        else if let kind = options.embeddingProviderKind { self.embeddingProvider = EmbeddingProviderFactory.make(kind: kind) }
        else { self.embeddingProvider = LocalModelEmbeddingProvider() }
        let learnedRules = (try? catalog.listRules()) ?? []
        self.processingVersion = Self.makeProcessingVersion(
            options: options, providerID: self.embeddingProvider.providerID,
            asrProviderIdentity: TranscriptionProviderState.processingIdentity(transcriptionProvider),
            learnedRules: learnedRules)
        self.transcriptionProvider = transcriptionProvider
        self.pcmDecoder = pcmDecoder ?? BrokerPCMDecoder(maxSnapshotBytes: options.maxMediaSnapshotBytes)
        self.embeddingAvailable = options.enableLocalEmbeddings && self.embeddingProvider.preflight.available
        try? catalog.recordEmbeddingSpace(
            version: Self.embeddingSpaceVersion,
            details: [
                "provider=\(self.embeddingProvider.providerID)",
                "imageModel=\(self.embeddingProvider.imageModelID)",
                "textModel=\(self.embeddingProvider.textModelID)",
                "preflight=\(self.embeddingProvider.preflight.available)"
            ].joined(separator: "|"))
    }

    /// Embedding-space version — derived from pinned HF SHAs + pipeline
    /// contract (processor revision, dim, poisoning prevention). Bump when any
    /// checkpoint SHA or embedding pipeline changes.
    public static let embeddingSpaceVersion = "emb-v2:clip-3d74acf9|siglip-7fd15f06|mclip-71aa3e13|dino-ed25f3a3|minilm-1110a243|dim-512+384"
    /// Full identity of the processing pipeline used for incremental invalidation.
    /// Includes embedding-space identity when Tier 2 is enabled so a model change
    /// forces at least one re-index of every file that carries an embedding.
    private static func makeProcessingVersion(options: Options, providerID: String? = nil,
                                              asrProviderIdentity: String? = nil,
                                              learnedRules: [LearnedRule] = []) -> String {
        var parts = [
            ChangeDetection.extractorVersion,
            "classifier:\(ChangeDetection.classifierVersion)",
            "vision:\(VisionImageAnalyzer.revision)",
        ]
        if options.enableOCR {
            parts.append("ocr:\(VisionOCR.revision)")
        }
        if options.enableLocalEmbeddings {
            let clip = LocalModelBridge.isProvisioned(.clipImage) ? "clip:on" : "clip:off"
            let mini = LocalModelBridge.isProvisioned(.miniLMText) ? "minilm:on" : "minilm:off"
            let prov = providerID ?? options.embeddingProviderKind ?? LocalModelEmbeddingProvider().providerID
            parts.append("tier2:\(clip),\(mini),\(embeddingSpaceVersion),provider:\(prov)")
        } else {
            parts.append("tier2:off")
        }
        // ASR output is generation-scoped just like embeddings. Enabling
        // ASR or changing the provider/binary/model identity forces exactly
        // one honest re-index; the same identity returns to zero-work skips.
        if options.enableLocalASR {
            parts.append("asr:on,provider:\(asrProviderIdentity ?? "unknown")")
        } else {
            parts.append("asr:off")
        }
        // A rule can already be enabled when the app starts, so queue-based
        // invalidation alone is insufficient across restarts. Include the
        // complete deterministic rule state in the generation contract; a
        // changed rule then forces one honest refresh even if its prior queue
        // entry was lost.
        var ruleHash: UInt64 = 1469598103934665603
        for rule in learnedRules {
            for byte in "\(rule.id)|\(rule.patternType.rawValue)|\(rule.pattern)|\(rule.targetCategory)|\(rule.confidence)|\(rule.enabled)|\(rule.created)\n".utf8 {
                ruleHash ^= UInt64(byte)
                ruleHash = ruleHash &* 1099511628211
            }
        }
        parts.append(String(format: "learned-rules:%016llx", ruleHash))
        return parts.joined(separator: "|")
    }

    /// Index a security-scoped root folder.
    /// Returns the number of entries that actually required processing; entries
    /// skipped by incremental detection are not counted. Progress still reports
    /// all discovered entries scanned so the UI can reach total/total.
    @discardableResult
    public func indexRoot(_ root: URL, onProgress: ((Progress) -> Void)? = nil) throws -> Int {
        let items = try SourceBroker.enumerate(root: root,
                                               excludedPrefixes: options.excludedPaths,
                                               excludedDirectoryNames: options.excludedDirectoryNames)
        var scanned = 0
        var actuallyProcessed = 0
        var similarityChangedIDs = Set<String>()
        var similarityRemovedIDs = Set<String>()
        let total = min(items.count, options.maxFiles ?? Int.max)
        let rootPrefix = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        let queuedByPath: [String: String] = {
            guard let entries = try? catalog.learnedReindexEntries() else { return [:] }
            return Dictionary(uniqueKeysWithValues: entries.filter { entry in
                SourceBroker.isPath(entry.path, under: rootPrefix)
                    && !options.excludedPaths.contains {
                        SourceBroker.isPath(entry.path, under: $0)
                    }
            }.map { ($0.path, $0.fileID) })
        }()
        // Session-scoped persistent worker — keeps models warm across many files.
        let worker: LocalModelBridge.PersistentWorker? = {
            guard options.enableLocalEmbeddings, embeddingAvailable,
                  embeddingProvider is LocalModelEmbeddingProvider else { return nil }
            guard LocalModelBridge.isProvisioned(.clipImage) || LocalModelBridge.isProvisioned(.miniLMText) else { return nil }
            return LocalModelBridge.PersistentWorker()
        }()
        defer { worker?.close() }

        for item in items.prefix(options.maxFiles ?? Int.max) {
            do {
                let classificationOnly = queuedByPath[item.path].flatMap { fileID in
                    try? reindexQueuedClassification(fileID: fileID, path: item.path)
                } == true
                let didProcess: Bool
                if classificationOnly {
                    didProcess = true
                } else {
                    didProcess = try indexOne(path: item.path, worker: worker,
                                              updateSimilarity: false)
                }
                if didProcess {
                    actuallyProcessed += 1
                    if let current = try? broker.identity(at: item.path) {
                        similarityChangedIDs.insert(FileID.make(identity: current))
                    }
                }
            } catch {
                try? catalog.recordError(opaqueRef: FileID.workerError(scanned + 1),
                                         stage: "index", message: String(describing: error).prefix(200).description)
            }
            scanned += 1
            if let onProgress {
                onProgress(Progress(processed: scanned, total: total,
                                    lastPath: (item.path as NSString).lastPathComponent))
            }
        }

        // Plan §34/§44: files that vanished since the last scan are marked
        // missing in the catalog — never reconstructed, never deleted twice.
        // The enumerator emits root.path-joined paths, so seen-set, this
        // prefix, and every catalog row share one spelling by construction.
        let seen = Set(items.map(\.path))
        for stored in try catalog.allFiles()
            where stored.status != "missing" && stored.status != "unscoped" {
            guard SourceBroker.isPath(stored.path, under: rootPrefix) else { continue }
            if options.excludedPaths.contains(where: { SourceBroker.isPath(stored.path, under: $0) }) { continue }
            if seen.contains(stored.path) { continue }
            // Depth-truncation guard: a file beyond maxDepth wasn't *seen*,
            // but it didn't vanish either. Absence must be PROVEN: only
            // ENOENT/ENOTDIR from the no-follow lstat count. EACCES, ELOOP,
            // etc. mean "can't look right now" — never "gone".
            do {
                _ = try broker.identity(at: stored.path)
                continue
            } catch BrokerError.statFailed(let errno)
                where errno == ENOENT || errno == ENOTDIR {
                if stored.path.split(separator: "/").contains(where: {
                    options.excludedDirectoryNames.contains(String($0))
                }) {
                    continue
                }
                try catalog.markMissing(path: stored.path)
                similarityRemovedIDs.insert(stored.id)
            } catch {
                continue
            }
        }
        if !similarityChangedIDs.isEmpty || !similarityRemovedIDs.isEmpty {
            try? rebuildSimilarityGraph(changedFileIDs: similarityChangedIDs,
                                        removedFileIDs: similarityRemovedIDs)
        }
        return actuallyProcessed
    }

    /// Re-apply learned classification rules from the already stored
    /// generation. This path intentionally does not call `EvidenceExtractor`,
    /// Vision, OCR, embeddings, hashing, or media decoders; rule changes only
    /// invalidate classification output.
    private func reindexQueuedClassification(fileID: String, path: String) throws -> Bool {
        guard let current = try? broker.identity(at: path),
              FileID.make(identity: current) == fileID,
              let stored = try catalog.storedState(forPath: path),
              stored.status == "indexed",
              stored.size == current.size,
              abs(stored.mtime - current.mtime.timeIntervalSince1970) <= 0.001 else {
            return false
        }
        let rows = try catalog.query("""
            SELECT categories_json, base_categories_json, description, confidence,
                   reason_codes_json, classifier
            FROM classifications WHERE file_id=?
            """, binds: [.text(fileID)]) { row in
                (
                    categories: row.text(0) ?? "[]",
                    baseCategories: row.text(1),
                    description: row.text(2) ?? "",
                    confidence: row.real(3),
                    reasons: row.text(4) ?? "[]",
                    classifier: row.text(5) ?? ChangeDetection.classifierVersion
                )
            }
        guard let row = rows.first else { return false }
        let decodeCategories: (String?) -> [String] = { value in
            guard let value, let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        let allRules = try catalog.listRules()
        let baseCategories: [String] = {
            if row.baseCategories != nil {
                return decodeCategories(row.baseCategories)
            }
            let knownTargets = Set(allRules.map(\.targetCategory))
            return decodeCategories(row.categories).filter { !knownTargets.contains($0) }
        }()
        var evidence = EvidenceExtractor.Evidence()
        evidence.filenameTokens = EvidenceExtractor.tokens((current.path as NSString).lastPathComponent)
        evidence.kind = current.kind.rawValue
        evidence.sizeClass = EvidenceExtractor.sizeClass(current.size)
        evidence.notes = try catalog.query("SELECT k, v FROM metadata WHERE file_id=?",
                                           binds: [.text(fileID)]) {
            "\($0.text(0) ?? "")=\($0.text(1) ?? "")"
        }

        // The queue path is still subject to the same generation boundary as
        // full indexing. A source mutation during catalog/evidence lookup
        // must leave the queue for the normal full re-index path.
        guard let final = try? broker.identity(at: path),
              current.stillMatches(final) else {
            return false
        }

        var committed = false
        try catalog.transaction {
            let overridden = try catalog.txApplyCategoryOverrides(
                fileID: fileID, categories: baseCategories)
            let enriched = LearnedRuleEngine(rules: allRules.filter(\.enabled))
                .enrich(categories: overridden, identity: current, evidence: evidence)
            let retainedReasons = decodeCategories(row.reasons)
                .filter { !$0.hasPrefix("learned:") }
            let candidate = Classification(
                fileID: fileID,
                categories: enriched.categories,
                description: row.description,
                confidence: row.confidence,
                reasonCodes: Array((retainedReasons + enriched.reasons)
                    .prefix(ClassifierContract.maxReasonCodes)))
            guard let data = try? candidate.jsonData(),
                  let validated = ClassifierContract.validate(data) else {
                return
            }
            let categoriesJSON = String(
                data: try JSONEncoder().encode(validated.categories), encoding: .utf8)!
            let baseJSON = String(
                data: try JSONEncoder().encode(baseCategories), encoding: .utf8)!
            let reasonsJSON = String(
                data: try JSONEncoder().encode(validated.reasonCodes), encoding: .utf8)!
            try catalog.txRun("""
                UPDATE classifications
                SET categories_json=?, base_categories_json=?, description=?,
                    confidence=?, reason_codes_json=?, classifier=?, created=?
                WHERE file_id=?
                """, binds: [
                    .text(categoriesJSON), .text(baseJSON), .text(validated.description),
                    .real(validated.confidence), .text(reasonsJSON), .text(row.classifier),
                    .real(Date().timeIntervalSince1970), .text(fileID)
                ])
            try catalog.txRun(
                "DELETE FROM category_membership WHERE file_id=? AND source='classifier'",
                binds: [.text(fileID)])
            for category in validated.categories {
                let categoryID = try catalog.txEnsureCategory(named: category)
                try catalog.txRun(
                    "INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
                    binds: [.int(categoryID), .text(fileID)])
            }
            let now = Date().timeIntervalSince1970
            if ReviewState.from(confidence: validated.confidence) == .confident
                || validated.categories.contains("Review/Unknown") {
                try catalog.txRun("DELETE FROM review_inbox WHERE file_id=? AND state='open'",
                                  binds: [.text(fileID)])
            } else {
                try catalog.txRun("""
                    INSERT INTO review_inbox(file_id, state, reason, created, updated)
                    VALUES(?, 'open', ?, ?, ?)
                    ON CONFLICT(file_id) DO UPDATE SET state='open',
                        reason=excluded.reason, updated=excluded.updated
                    """, binds: [.text(fileID),
                                  .text(validated.reasonCodes.joined(separator: ",")),
                                  .real(now), .real(now)])
            }
            try catalog.txRun(
                "DELETE FROM learned_reindex_queue WHERE file_id=?",
                binds: [.text(fileID)])
            try catalog.txRun(
                "UPDATE files SET last_extractor=? WHERE id=?",
                binds: [.text(processingVersion), .text(fileID)])
            committed = true
        }
        return committed
    }

    /// Index a single file end-to-end with race detection.
    /// Returns false when the stored identity + processing version prove the
    /// entry is unchanged, before any extraction/Vision/Tier-2 work occurs.
    @discardableResult
    public func indexOne(path: String, worker: LocalModelBridge.PersistentWorker? = nil,
                         updateSimilarity: Bool = true) throws -> Bool {
        // 1. Identity BEFORE processing.
        guard let ident = try? broker.identity(at: path) else { return false }

        // Critical efficiency gate: this must happen before upsert, extraction,
        // Vision, hashing, or Tier-2 subprocesses. The old implementation had
        // ChangeDetection code but never called it.
        if let stored = try catalog.storedState(forPath: path),
           !ChangeDetection.needsProcessing(stored: stored,
                                            current: ident,
                                            requiredExtractorVersion: processingVersion) {
            // Cloud hydration can change allocated storage without changing
            // the logical size or timestamps. Recheck this non-hydrating
            // resource state so a placeholder is revisited when its bytes
            // become available (and vice versa).
            // Resource-value lookup follows a symlink on macOS. A link is
            // already a terminal metadata record, so never interpret its
            // target's allocation state as a cloud-placeholder transition.
            let cloudStateChanged = !ident.isSymlink && (stored.status == "cloud-placeholder"
                ? !EvidenceExtractor.isCloudPlaceholder(at: path)
                : EvidenceExtractor.isCloudPlaceholder(at: path))
            if !cloudStateChanged { return false }
        }

        let id = FileID.make(identity: ident)
        defer {
            if updateSimilarity {
                try? rebuildSimilarityGraph(changedFileIDs: [id])
            }
        }

        if ident.isSymlink {
            // Plan §22: index the link itself as metadata. Never open it.
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "pending")
            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "indexed")
            // A path that is no longer a decodable regular file cannot stand
            // behind its old generation's transcript.
            try catalog.purgeDerivedData(fileID: id)
            return true
        }

        // Cloud placeholders are recorded but never hydrated (plan §24).
        if EvidenceExtractor.isCloudPlaceholder(at: path) {
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "pending")
            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "cloud-placeholder")
            // Placeholder bytes are not present; any earlier transcript does
            // not describe this generation.
            try catalog.purgeDerivedData(fileID: id)
            return true
        }

        // Upsert updates the current size/mtime. Immediately mark pending so a
        // crash cannot leave the new fingerprint carrying an old 'indexed'
        // status and cause the next run to skip stale derived data.
        try catalog.upsertFile(identity: ident, id: id)
        try catalog.setStatus(fileID: id, status: "pending")

        // 2. Extract bounded evidence + content (pure derives; not durably committed yet).
        let ev = evidence.extract(identity: ident)
        var textContent: String? = ev.textSample

        switch ident.kind {
        case .pdf:
            if let pdfData = try? broker.completeSnapshot(path, maxBytes: 64 * 1024 * 1024),
               let pdfText = PDFText.extract(data: pdfData) {
                textContent = String(pdfText.prefix(200_000))
            }
        case .text:
            break
        default:
            break
        }
        // 2a. Broker bytes for image embedding are held here so the helper path
        // never sees the raw filesystem path.
        var imageBytes: Data? = nil
        if ident.kind == .image {
            imageBytes = try? broker.completeSnapshot(ident.path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes)
        }

        // 2b. OCR injection after PDF/Office extraction — broker-bytes only, MEDIUM scheduler.
        var ocrResult: VisionOCR.Result? = nil
        var ocrExtractor: String? = nil
        if options.enableOCR {
            if ident.kind == .image, let bytes = imageBytes, !bytes.isEmpty {
                recordWork { $0.ocrCalls += 1 }
                ocrResult = scheduler.perform(as: .medium) { [self] () -> VisionOCR.Result? in
                    visionOCR.recognize(imageData: bytes)
                }
                if ocrResult != nil { ocrExtractor = "vision-ocr" }
            } else if ident.kind == .pdf, VisionOCR.needsOCR(pdfText: textContent) {
                recordWork { $0.ocrCalls += 1 }
                ocrResult = scheduler.perform(as: .medium) { [self] () -> VisionOCR.Result? in
                    visionOCR.recognizeScannedPDF(
                        at: ident.path, broker: broker, pdfText: textContent,
                        maxBytes: options.maxMediaSnapshotBytes)
                }
                if ocrResult != nil { ocrExtractor = "pdfkit+vision-ocr" }
            }
            if let ocr = ocrResult, !ocr.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let trimmed = ocr.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let existing = textContent, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    textContent = existing + "\n" + trimmed
                } else {
                    textContent = trimmed
                }
            }
        }

        // 3a. Vision image analysis — images only (on-device, no download).
        // Video frame extraction is Stage E; raw video bytes cannot be classified.
        // Runs under MEDIUM slot; failures are non-fatal.
        var visionLabels: [(String, Float)] = []
        var screenshotAssessment: ScreenshotAssessment?
        var stagedFeaturePrint: (Data, String)? = nil
        if ident.kind == .image, let bytes = imageBytes, !bytes.isEmpty {
            recordWork { $0.visionCalls += 1 }
            let vRes: VisionImageAnalyzer.Result? = scheduler.perform(as: .medium) { [self] () -> VisionImageAnalyzer.Result? in
                // The analyzer receives broker-supplied bytes only. It never
                // receives a source path or folder authority.
                // Vision OCR is a separate, metered stage below. Avoid
                // requesting it twice for every image.
                visionAnalyzer.analyze(data: bytes, includeOCR: false)
            }
            if let vr = vRes {
                visionLabels = vr.classifications
                if let ocr = vr.recognizedText, !ocr.isEmpty { textContent = ocr }
                if let fp = vr.featurePrint, !fp.isEmpty {
                    stagedFeaturePrint = (fp, vr.featureRevision)
                }
            }
            let metadata = ScreenshotIntelligence.metadata(from: bytes)
            screenshotAssessment = ScreenshotIntelligence().assess(
                filename: (ident.path as NSString).lastPathComponent,
                metadata: metadata,
                ocrText: textContent,
                visionLabels: visionLabels.map { $0.0 })
        }

        // MARK: Media lane — audio/video probe + gating + sparse video frames

        // Sparse video sampling (self-contained, no audio decode). Runs under MEDIUM slot.
        var videoFrameCount: Int = 0
        if ident.kind == .video {
            // Complete broker snapshot for sampling; oversize containers fail closed.
            if let vBytes = try? broker.completeSnapshot(ident.path, maxBytes: options.maxMediaSnapshotBytes), !vBytes.isEmpty {
                let ext = (ident.path as NSString).pathExtension
                videoFrameCount = scheduler.perform(as: .medium) {
                    VideoSampler.sampleFrames(bytes: vBytes, fileExtension: ext.isEmpty ? nil : ext)
                }
                _ = videoFrameCount // no-op: frame count confirms pipeline self-containment
            }
        }

        // Audio/speech gating: probe -> gate -> explicit transcription outcome.
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

        // Stage Tier-2 embeddings without touching the catalog yet.
        // Prefer the session worker (warm models) when available; fall back to
        // per-file cold start for single-file callers.
        var stagedClip: EmbeddingVector? = nil
        if ident.kind == .image, let bytes = imageBytes, !bytes.isEmpty,
           embeddingAvailable {
            recordWork { $0.clipCalls += 1 }
            if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
               let result = w.embedImageBytes(bytes, timeout: 15) {
                stagedClip = EmbeddingVector(spaceID: "image:\(embeddingProvider.providerID)",
                                             dim: result.dim, data: result.data)
            } else {
                stagedClip = scheduler.perform(as: .medium) { [embeddingProvider] in
                    embeddingProvider.embedImageBytes(bytes)
                }
            }
            if stagedClip?.data.isEmpty == true { stagedClip = nil }
        }
        var stagedMiniLM: EmbeddingVector? = nil
        var stagedChunks: [(index: Int, data: Data, dim: Int)] = []
        if options.enableLocalEmbeddings,
           let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           embeddingAvailable {
            recordWork { $0.textEmbedCalls += 1 }
            if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
               let result = w.embedText(t, timeout: 10) {
                stagedMiniLM = EmbeddingVector(spaceID: "text:\(embeddingProvider.providerID)",
                                               dim: result.dim, data: result.data)
            } else {
                stagedMiniLM = scheduler.perform(as: .medium) { [embeddingProvider] in
                    embeddingProvider.embedText(t)
                }
            }
            if stagedMiniLM?.data.isEmpty == true { stagedMiniLM = nil }
            // Pre-compute chunk embeddings *outside* the transaction so no
            // Python/model call holds the DB commit open.
            let chunks = LocalModelBridge.textChunks(t)
            if chunks.count > 1 {
                for (idx, chunk) in chunks.enumerated() {
                    recordWork { $0.textEmbedCalls += 1 }
                    if let w = worker, embeddingProvider is LocalModelEmbeddingProvider,
                       let ce = w.embedText(chunk, timeout: 8), !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    } else if let ce = scheduler.perform(as: .medium, { [embeddingProvider] in
                        embeddingProvider.embedText(chunk)
                    }),
                              !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    }
                }
            }
        }

        // 3b. Classify (deterministic v1 + vision labels) under MEDIUM slot.
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent,
                                visionLabels: visionLabels, screenshot: screenshotAssessment)
        }
        var validatedClass: Classification? = {
            guard let data = try? classification.jsonData() else { return nil }
            return ClassifierContract.validate(data)
        }()
        let baseCategories = validatedClass?.categories
        // Apply only enabled, evidence-bound rules after the base classifier.
        // Re-validate the merged result so learned data cannot bypass the
        // classifier contract wall.
        if let base = validatedClass,
           let rules = try? catalog.enabledRules(),
           !rules.isEmpty {
            let enriched = LearnedRuleEngine(rules: rules)
                .enrich(categories: base.categories, identity: ident, evidence: ev)
            if !enriched.reasons.isEmpty || enriched.categories != base.categories {
                let reasons = Array((base.reasonCodes + enriched.reasons)
                    .prefix(ClassifierContract.maxReasonCodes))
                let trial = Classification(fileID: base.fileID,
                                            categories: Array(enriched.categories.prefix(ClassifierContract.maxCategories)),
                                            description: base.description,
                                            confidence: base.confidence,
                                            reasonCodes: reasons)
                if let data = try? trial.jsonData(),
                   let validated = ClassifierContract.validate(data) {
                    validatedClass = validated
                }
            }
        }
        let hashToRecord: Data? = {
            guard (try? Self.shouldHashCandidate(fileID: id, identity: ident, catalog: catalog)) == true else { return nil }
            return try? DuplicateDetector.sha256(path: ident.path, broker: broker)
        }()

        // 4. Re-stat BEFORE touching any derived table. If the file mutated during
        // the (potentially expensive) Vision/Tier2 work, we must not commit derived
        // data belonging to the now-stale generation.
        guard let now = try? broker.identity(at: path), ident.stillMatches(now) else {
            try catalog.setStatus(fileID: id, status: "changed-during-index")
            return true
        }

        // 5. Atomically commit the entire derived set for this generation so a
        // crash or torn write cannot leave FTS, classifications, features, and
        // embeddings inconsistent about the file generation they describe.
        do {
            try catalog.transaction {
                // Derived rows are generation-scoped. Clear the complete
                // previous generation before inserting this one so a changed
                // file cannot retain stale OCR, vectors, hashes, screenshots,
                // or transcript evidence when a later extractor produces no
                // replacement.
                for table in ["text_fts", "text_content", "classifications",
                              "screenshot_assessments", "visual_features",
                              "embeddings", "embedding_chunks", "transcripts",
                              "transcripts_fts", "exact_hashes"] {
                    try catalog.txRun("DELETE FROM \(table) WHERE file_id=?", binds: [.text(id)])
                }
                // Classification failure must not leave the previous
                // generation's virtual memberships or open review item
                // visible beside the new generation.
                try catalog.txRun(
                    "DELETE FROM category_membership WHERE file_id=? AND source='classifier'",
                    binds: [.text(id)])
                try catalog.txRun(
                    "DELETE FROM review_inbox WHERE file_id=? AND state='open'",
                    binds: [.text(id)])
                if let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let extractor = ocrExtractor ?? ((ident.kind == .pdf) ? "pdfkit" : "utf8")
                    try catalog.txRun("DELETE FROM text_fts WHERE file_id=?", binds: [.text(id)])
                    try catalog.txRun("""
                        INSERT INTO text_content(file_id, body, extractor, created) VALUES(?,?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET body=excluded.body, extractor=excluded.extractor, created=excluded.created
                        """, binds: [.text(id), .text(t), .text(extractor), .real(Date().timeIntervalSince1970)])
                    try catalog.txRun("INSERT INTO text_fts(file_id, body) VALUES(?,?)", binds: [.text(id), .text(t)])
                }
                if let validated = validatedClass {
                    let reasons = String(data: try JSONEncoder().encode(validated.reasonCodes), encoding: .utf8)!
                    let effectiveCategories = try catalog.txApplyCategoryOverrides(
                        fileID: validated.fileID, categories: validated.categories)
                    try catalog.txRun("""
                        INSERT INTO classifications(file_id, categories_json, base_categories_json, description, confidence, reason_codes_json, classifier, created)
                        VALUES(?,?,?,?,?,?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET
                            categories_json=excluded.categories_json, description=excluded.description,
                            base_categories_json=excluded.base_categories_json,
                            confidence=excluded.confidence, reason_codes_json=excluded.reason_codes_json,
                            classifier=excluded.classifier, created=excluded.created
                        """, binds: [.text(validated.fileID), .text(String(data: try JSONEncoder().encode(effectiveCategories), encoding: .utf8)!),
                                      .text(String(data: try JSONEncoder().encode(baseCategories ?? validated.categories), encoding: .utf8)!),
                                      .text(validated.description),
                                      .real(validated.confidence), .text(reasons),
                                      .text(ChangeDetection.classifierVersion), .real(Date().timeIntervalSince1970)])
                    try catalog.txRun("DELETE FROM category_membership WHERE file_id=? AND source='classifier'", binds: [.text(validated.fileID)])
                    for cat in effectiveCategories {
                        let catID = try catalog.txEnsureCategory(named: cat)
                        try catalog.txRun("INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
                                          binds: [.int(catID), .text(validated.fileID)])
                    }
                    let now = Date().timeIntervalSince1970
                    if ReviewState.from(confidence: validated.confidence) == .confident
                        || effectiveCategories.contains("Review/Unknown") {
                        try catalog.txRun("DELETE FROM review_inbox WHERE file_id=? AND state='open'",
                                          binds: [.text(validated.fileID)])
                    } else {
                        try catalog.txRun("""
                            INSERT INTO review_inbox(file_id, state, reason, created, updated)
                            VALUES(?, 'open', ?, ?, ?)
                            ON CONFLICT(file_id) DO UPDATE SET state='open', reason=excluded.reason, updated=excluded.updated
                            """, binds: [.text(validated.fileID), .text(validated.reasonCodes.joined(separator: ",")),
                                           .real(now), .real(now)])
                    }
                } else {
                    try catalog.txRun("INSERT INTO errors(opaque_ref, stage, message, created) VALUES(?,?,?,?)",
                                      binds: [.text(id), .text("classifier"), .text("output failed schema validation; discarded"),
                                              .real(Date().timeIntervalSince1970)])
                }
                if let screenshotAssessment {
                    try catalog.txSaveScreenshotAssessment(fileID: id, assessment: screenshotAssessment)
                }
                if let (fp, rev) = stagedFeaturePrint {
                    try catalog.txRun("""
                        INSERT INTO visual_features(file_id, featureprint, revision) VALUES(?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET featureprint=excluded.featureprint, revision=excluded.revision
                        """, binds: [.text(id), .blob(fp), .text(rev)])
                }
                if let emb = stagedClip {
                    try catalog.txRun("""
                        INSERT INTO embeddings(file_id, model, dim, vector) VALUES(?,?,?,?)
                        ON CONFLICT(file_id, model) DO UPDATE SET dim=excluded.dim, vector=excluded.vector
                        """, binds: [.text(id), .text(embeddingProvider.imageModelID), .int(Int64(emb.dim)), .blob(emb.data)])
                }
                if let tr = stagedTranscript, !tr.segments.isEmpty {
                    // Atomic replacement: the old generation's rows (and FTS
                    // entries) are deleted and the new ones inserted inside
                    // this same transaction, so no reader can observe a mix.
                    try catalog.txSaveTranscript(fileID: id, provider: tr.provider, segments: tr.segments)
                } else {
                    // Generation-safety invariant: after a generation commits,
                    // the file's transcript state must reflect THAT generation.
                    // If it produced no transcript — decode failed, it no
                    // longer qualifies for ASR, ASR is disabled, or the file
                    // is no longer media at all — any previous generation's
                    // transcript is purged here, so stale speech is never
                    // presented as current. For non-media files the DELETE
                    // touches zero rows.
                    try catalog.txRun("DELETE FROM transcripts WHERE file_id=?", binds: [.text(id)])
                    try catalog.txRun("DELETE FROM transcripts_fts WHERE file_id=?", binds: [.text(id)])
                }
                if let emb = stagedMiniLM {
                    if !stagedChunks.isEmpty {
                        try catalog.txRun("DELETE FROM embedding_chunks WHERE file_id=? AND model=?",
                                          binds: [.text(id), .text(embeddingProvider.textModelID)])
                        for ch in stagedChunks {
                            try catalog.txRun("INSERT INTO embedding_chunks(file_id, model, chunk_index, dim, vector) VALUES(?,?,?,?,?)",
                                              binds: [.text(id), .text(embeddingProvider.textModelID),
                                                      .int(Int64(ch.index)), .int(Int64(ch.dim)), .blob(ch.data)])
                        }
                    }
                    try catalog.txRun("""
                        INSERT INTO embeddings(file_id, model, dim, vector) VALUES(?,?,?,?)
                        ON CONFLICT(file_id, model) DO UPDATE SET dim=excluded.dim, vector=excluded.vector
                        """, binds: [.text(id), .text(embeddingProvider.textModelID), .int(Int64(emb.dim)), .blob(emb.data)])
                }
                if let digest = hashToRecord {
                    try catalog.txRun("""
                        INSERT INTO exact_hashes(file_id, size, sha256, computed) VALUES(?,?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET sha256=excluded.sha256, computed=excluded.computed
                        """, binds: [.text(id), .int(ident.size), .blob(digest), .real(Date().timeIntervalSince1970)])
                }
                try catalog.txRun("UPDATE files SET last_extractor=? WHERE id=?", binds: [.text(processingVersion), .text(id)])
                try catalog.txRun("DELETE FROM learned_reindex_queue WHERE file_id=?", binds: [.text(id)])
                try catalog.txRun("UPDATE files SET status='indexed' WHERE id=?", binds: [.text(id)])
            }
        } catch {
            try? catalog.recordError(opaqueRef: id, stage: "index-commit", message: String(describing: error).prefix(200).description)
            throw error
        }
        return true
    }

    /// Rebuild only the affected similarity neighborhoods while retaining
    /// unaffected edges. The graph is derived SQLCipher state; this operation
    /// never reads or mutates source files directly.
    public func rebuildSimilarityGraph(changedFileIDs: Set<String> = [],
                                       removedFileIDs: Set<String> = []) throws {
        let started = Date()
        let nodes = try catalog.similarityNodes()
        let existing = try catalog.similarityEdges()
        var adapters: [any SimilarityEdgeAdapter] = [
            ExactHashEdgeAdapter(nodes: nodes),
            FeaturePrintEdgeAdapter(scorer: VisionFeaturePrintSimilarityScorer(),
                                    minimumScore: 0.50)
        ]
        let models = Set(nodes.flatMap { $0.embeddings.keys }).sorted()
        for model in models {
            adapters.append(EmbeddingEdgeAdapter(model: model,
                                                 scorer: CatalogEmbeddingSimilarityScorer(),
                                                 minimumScore: 0.75))
        }
        let changed = changedFileIDs.isEmpty && existing.isEmpty
            ? Set(nodes.map(\.id))
            : changedFileIDs
        let update = similarityClustering.incrementalUpdate(
            nodes: nodes,
            existingEdges: existing,
            changedNodeIDs: changed,
            removedNodeIDs: removedFileIDs,
            adapters: adapters,
            minimumScore: 0.50
        )
        try catalog.replaceSimilarityGraph(update)
        metricsLock.lock()
        lastSimilarityMetrics = SimilarityMetrics(
            seconds: Date().timeIntervalSince(started),
            changedNodes: changed.count,
            edges: update.edges.count,
            clusters: update.clusters.count)
        metricsLock.unlock()
    }

    /// Size-bucket candidate groups across the whole catalog, then confirm
    /// exact duplicates with partial fingerprint → full SHA-256.
    public func computeDuplicateGroups() throws -> [[String]] {
        let files = try catalog.allFiles(statuses: ["indexed"])
        var sizes: [String: Int64] = [:]
        for f in files { sizes[f.id] = f.size }
        let groups = DuplicateDetector.candidateGroups(sizes: sizes)
        var confirmed: [[String]] = []

        for group in groups {
            // Partial fingerprints first.
            var byFingerprint: [String: [String]] = [:]
            for fileID in group {
                guard let row = try catalog.fileRow(id: fileID) else { continue }
                guard let fp = try? DuplicateDetector.partialFingerprint(path: row.path, size: row.size, broker: broker) else { continue }
                let key = Self.fpKey(fp)
                byFingerprint[key, default: []].append(fileID)
            }
            // Full SHA-256 within matching partial groups only.
            for (_, members) in byFingerprint where members.count > 1 {
                var byFull: [Data: [String]] = [:]
                for fileID in members {
                    guard let row = try catalog.fileRow(id: fileID) else { continue }
                    guard let digest = try? DuplicateDetector.sha256(path: row.path, broker: broker) else { continue }
                    try? catalog.recordHash(fileID: fileID, size: row.size, sha256: digest)
                    byFull[digest, default: []].append(fileID)
                }
                for (_, ids) in byFull where ids.count > 1 {
                    confirmed.append(ids.sorted())
                }
            }
        }
        return confirmed
    }

    static func fpKey(_ fp: DuplicateDetector.PartialFingerprint) -> String {
        var hasher = Hasher()
        hasher.combine(fp.size)
        hasher.combine(fp.head)
        hasher.combine(fp.middle)
        hasher.combine(fp.tail)
        return String(hasher.finalize())
    }

    /// Opportunistic hashing when this file already shares its size with another known file.
    /// Used only for the staged-commit path — caller supplies a precomputed digest.
    private static func shouldHashCandidate(fileID: String, identity: FileIdentity, catalog: Catalog) throws -> Bool {
        let sameSize = try catalog.query(
            "SELECT count(*) FROM files WHERE size=? AND id!=?", binds: [.int(identity.size), .text(fileID)]) { $0.int(0) }
        return (sameSize.first ?? 0) > 0
    }
}

private struct VisionFeaturePrintSimilarityScorer: FeaturePrintScorer {
    func score(_ lhs: Data, _ rhs: Data) -> Float? {
        guard let distance = VisionImageAnalyzer.distance(lhs, rhs) else { return nil }
        return max(0, 1 - distance)
    }
}

private struct CatalogEmbeddingSimilarityScorer: EmbeddingScorer {
    func score(_ lhs: Data, _ rhs: Data, model: String) -> Float? {
        LocalModelBridge.cosineSimilarity(lhs, rhs)
    }
}
