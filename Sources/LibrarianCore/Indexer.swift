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
        public init() {}
    }

    public struct Progress: Sendable {
        /// Number of discovered entries scanned, including unchanged skips.
        public let processed: Int
        public let total: Int
        public let lastPath: String
    }

    private let broker: SourceBroker
    private let catalog: Catalog
    private let scheduler: Scheduler
    private let evidence: EvidenceExtractor
    private let classifier = RuleBasedClassifier()
    private let visionAnalyzer = VisionImageAnalyzer()
    private let options: Options
    private let processingVersion: String

    public init(broker: SourceBroker, catalog: Catalog, scheduler: Scheduler, options: Options = .init()) {
        self.broker = broker
        self.catalog = catalog
        self.scheduler = scheduler
        self.options = options
        self.evidence = EvidenceExtractor(broker: broker)
        self.processingVersion = Self.makeProcessingVersion(options: options)
    }

    /// Embedding-space version — derived from pinned HF SHAs + pipeline
    /// contract (processor revision, dim, poisoning prevention). Bump when any
    /// checkpoint SHA or embedding pipeline changes.
    public static let embeddingSpaceVersion = "emb-v2:clip-3d74acf9|siglip-7fd15f06|mclip-71aa3e13|dino-ed25f3a3|minilm-1110a243|dim-512+384"
    /// Full identity of the processing pipeline used for incremental invalidation.
    /// Includes embedding-space identity when Tier 2 is enabled so a model change
    /// forces at least one re-index of every file that carries an embedding.
    private static func makeProcessingVersion(options: Options) -> String {
        var parts = [
            ChangeDetection.extractorVersion,
            "classifier:\(ChangeDetection.classifierVersion)",
            "vision:\(VisionImageAnalyzer.revision)",
        ]
        if options.enableLocalEmbeddings {
            let clip = LocalModelBridge.isProvisioned(.clipImage) ? "clip:on" : "clip:off"
            let mini = LocalModelBridge.isProvisioned(.miniLMText) ? "minilm:on" : "minilm:off"
            parts.append("tier2:\(clip),\(mini),\(embeddingSpaceVersion)")
        } else {
            parts.append("tier2:off")
        }
        return parts.joined(separator: "|")
    }

    /// Index a security-scoped root folder.
    /// Returns the number of entries that actually required processing; entries
    /// skipped by incremental detection are not counted. Progress still reports
    /// all discovered entries scanned so the UI can reach total/total.
    @discardableResult
    public func indexRoot(_ root: URL, onProgress: ((Progress) -> Void)? = nil) throws -> Int {
        let items = try SourceBroker.enumerate(root: root)
        var scanned = 0
        var actuallyProcessed = 0
        let total = min(items.count, options.maxFiles ?? Int.max)
        // Session-scoped persistent worker — keeps models warm across many files.
        let worker: LocalModelBridge.PersistentWorker? = {
            guard options.enableLocalEmbeddings else { return nil }
            guard LocalModelBridge.isProvisioned(.clipImage) || LocalModelBridge.isProvisioned(.miniLMText) else { return nil }
            return LocalModelBridge.PersistentWorker()
        }()
        defer { worker?.close() }

        for item in items.prefix(options.maxFiles ?? Int.max) {
            do {
                if try indexOne(path: item.path, worker: worker) {
                    actuallyProcessed += 1
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
        let rootPrefix = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        for stored in try catalog.allFiles() where stored.status != "missing" {
            guard stored.path.hasPrefix(rootPrefix + "/") else { continue }
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
                try catalog.markMissing(path: stored.path)
            } catch {
                continue
            }
        }
        return actuallyProcessed
    }

    /// Index a single file end-to-end with race detection.
    /// Returns false when the stored identity + processing version prove the
    /// entry is unchanged, before any extraction/Vision/Tier-2 work occurs.
    @discardableResult
    public func indexOne(path: String, worker: LocalModelBridge.PersistentWorker? = nil) throws -> Bool {
        // 1. Identity BEFORE processing.
        guard let ident = try? broker.identity(at: path) else { return false }

        // Critical efficiency gate: this must happen before upsert, extraction,
        // Vision, hashing, or Tier-2 subprocesses. The old implementation had
        // ChangeDetection code but never called it.
        if let stored = try catalog.storedState(forPath: path),
           !ChangeDetection.needsProcessing(stored: stored,
                                            current: ident,
                                            requiredExtractorVersion: processingVersion) {
            return false
        }

        let id = FileID.make(identity: ident)

        if ident.isSymlink {
            // Plan §22: index the link itself as metadata. Never open it.
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "pending")
            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "indexed")
            return true
        }

        // Cloud placeholders are recorded but never hydrated (plan §24).
        if EvidenceExtractor.isCloudPlaceholder(at: path) {
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "pending")
            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "cloud-placeholder")
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
            if let pdfText = PDFText.extract(path: path, broker: broker) {
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
            imageBytes = try? broker.boundedRead(ident.path, limit: Int64(VisionImageAnalyzer.maxVisionBytes))
        }

        // 3a. Vision image analysis — images only (on-device, no download).
        // Video frame extraction is Stage E; raw video bytes cannot be classified.
        // Runs under MEDIUM slot; failures are non-fatal.
        var visionLabels: [(String, Float)] = []
        var stagedFeaturePrint: (Data, String)? = nil
        if ident.kind == .image {
            let vRes: VisionImageAnalyzer.Result? = scheduler.perform(as: .medium) { [self] () -> VisionImageAnalyzer.Result? in
                visionAnalyzer.analyze(path: ident.path, broker: broker)
            }
            if let vr = vRes {
                visionLabels = vr.classifications
                if let fp = vr.featurePrint, !fp.isEmpty {
                    stagedFeaturePrint = (fp, vr.featureRevision)
                }
            }
        }

        // Stage Tier-2 embeddings without touching the catalog yet.
        // Prefer the session worker (warm models) when available; fall back to
        // per-file cold start for single-file callers.
        var stagedClip: (dim: Int, data: Data)? = nil
        if ident.kind == .image, let bytes = imageBytes, !bytes.isEmpty,
           options.enableLocalEmbeddings, LocalModelBridge.isProvisioned(.clipImage) {
            if let w = worker {
                stagedClip = w.embedImageBytes(bytes, timeout: 15)
            } else {
                stagedClip = scheduler.perform(as: .medium) { () -> (dim: Int, data: Data)? in
                    LocalModelBridge.embedImageBytes(bytes, timeout: 15)
                }
            }
            if stagedClip?.data.isEmpty == true { stagedClip = nil }
        }
        var stagedMiniLM: (dim: Int, data: Data)? = nil
        var stagedChunks: [(index: Int, data: Data, dim: Int)] = []
        if options.enableLocalEmbeddings,
           let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           LocalModelBridge.isProvisioned(.miniLMText) {
            if let w = worker {
                stagedMiniLM = w.embedText(t, timeout: 10)
            } else {
                stagedMiniLM = scheduler.perform(as: .medium) { LocalModelBridge.embedText(t) }
            }
            if stagedMiniLM?.data.isEmpty == true { stagedMiniLM = nil }
            // Pre-compute chunk embeddings *outside* the transaction so no
            // Python/model call holds the DB commit open.
            let chunks = LocalModelBridge.textChunks(t)
            if chunks.count > 1 {
                for (idx, chunk) in chunks.enumerated() {
                    if let w = worker, let ce = w.embedText(chunk, timeout: 8), !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    } else if worker == nil,
                              let ce = scheduler.perform(as: .medium, { LocalModelBridge.embedText(chunk) }),
                              !ce.data.isEmpty {
                        stagedChunks.append((idx, ce.data, ce.dim))
                    }
                }
            }
        }

        // 3b. Classify (deterministic v1 + vision labels) under MEDIUM slot.
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent, visionLabels: visionLabels)
        }
        var validatedClass: Classification? = {
            guard let data = try? classification.jsonData() else { return nil }
            return ClassifierContract.validate(data)
        }()
        // Post-classifier deterministic enrichment from enabled learned rules (Issue #20).
        if var vc = validatedClass {
            if let ruleRows = try? catalog.enabledRules(), !ruleRows.isEmpty {
                let engine = LearnedRuleEngine(rules: ruleRows)
                let res = engine.enrich(categories: vc.categories, identity: ident, evidence: ev)
                let dupCats = res.categories.count != Set(res.categories).count
                if !res.reasons.isEmpty || res.categories != vc.categories {
                    // Re-validate after enrichment (categories still must pass contract charset).
                    let merged = res.categories
                    let mergedReasons = (vc.reasonCodes + res.reasons).prefix(ClassifierContract.maxReasonCodes).map { $0 }
                    // Clamp categories to max
                    let finalCats = Array(merged.prefix(ClassifierContract.maxCategories))
                    // Build a new Classification preserving fileID/description/confidence, extended categories/reasons.
                    let trial = Classification(fileID: vc.fileID, categories: finalCats, description: vc.description, confidence: vc.confidence, reasonCodes: Array(mergedReasons))
                    if let d = try? trial.jsonData(), let ok = ClassifierContract.validate(d) {
                        vc = ok
                        validatedClass = ok
                    }
                }
                _ = dupCats
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
                if let t = textContent, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let extractor = (ident.kind == .pdf) ? "pdfkit" : "utf8"
                    try catalog.txRun("DELETE FROM text_fts WHERE file_id=?", binds: [.text(id)])
                    try catalog.txRun("""
                        INSERT INTO text_content(file_id, body, extractor, created) VALUES(?,?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET body=excluded.body, extractor=excluded.extractor, created=excluded.created
                        """, binds: [.text(id), .text(t), .text(extractor), .real(Date().timeIntervalSince1970)])
                    try catalog.txRun("INSERT INTO text_fts(file_id, body) VALUES(?,?)", binds: [.text(id), .text(t)])
                }
                if let validated = validatedClass {
                    let cats = String(data: try JSONEncoder().encode(validated.categories), encoding: .utf8)!
                    let reasons = String(data: try JSONEncoder().encode(validated.reasonCodes), encoding: .utf8)!
                    try catalog.txRun("""
                        INSERT INTO classifications(file_id, categories_json, description, confidence, reason_codes_json, classifier, created)
                        VALUES(?,?,?,?,?,?,?)
                        ON CONFLICT(file_id) DO UPDATE SET
                            categories_json=excluded.categories_json, description=excluded.description,
                            confidence=excluded.confidence, reason_codes_json=excluded.reason_codes_json,
                            classifier=excluded.classifier, created=excluded.created
                        """, binds: [.text(validated.fileID), .text(cats), .text(validated.description),
                                      .real(validated.confidence), .text(reasons),
                                      .text("rule-based-v1"), .real(Date().timeIntervalSince1970)])
                    try catalog.txRun("DELETE FROM category_membership WHERE file_id=? AND source='classifier'", binds: [.text(validated.fileID)])
                    for cat in validated.categories {
                        let catID = try catalog.txEnsureCategory(named: cat)
                        try catalog.txRun("INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
                                          binds: [.int(catID), .text(validated.fileID)])
                    }
                } else {
                    try catalog.txRun("INSERT INTO errors(opaque_ref, stage, message, created) VALUES(?,?,?,?)",
                                      binds: [.text(id), .text("classifier"), .text("output failed schema validation; discarded"),
                                              .real(Date().timeIntervalSince1970)])
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
                        """, binds: [.text(id), .text(LocalModelBridge.Model.clipImage.rawValue), .int(Int64(emb.dim)), .blob(emb.data)])
                }
                if let emb = stagedMiniLM {
                    if !stagedChunks.isEmpty {
                        try catalog.txRun("DELETE FROM embedding_chunks WHERE file_id=? AND model=?",
                                          binds: [.text(id), .text(LocalModelBridge.Model.miniLMText.rawValue)])
                        for ch in stagedChunks {
                            try catalog.txRun("INSERT INTO embedding_chunks(file_id, model, chunk_index, dim, vector) VALUES(?,?,?,?,?)",
                                              binds: [.text(id), .text(LocalModelBridge.Model.miniLMText.rawValue),
                                                      .int(Int64(ch.index)), .int(Int64(ch.dim)), .blob(ch.data)])
                        }
                    }
                    try catalog.txRun("""
                        INSERT INTO embeddings(file_id, model, dim, vector) VALUES(?,?,?,?)
                        ON CONFLICT(file_id, model) DO UPDATE SET dim=excluded.dim, vector=excluded.vector
                        """, binds: [.text(id), .text(LocalModelBridge.Model.miniLMText.rawValue), .int(Int64(emb.dim)), .blob(emb.data)])
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
