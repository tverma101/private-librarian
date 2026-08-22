import Foundation

/// Deterministic indexing pipeline (plan §32):
///   event → deterministic queue → extractor → classifier → catalog update.
/// No autonomous agent, no watchers that write, no LLM in the loop for v1.
///
/// Race safety (plan §21): identity is captured before processing and re-stat'd
/// immediately before commit; a changed file has its result discarded.
public final class Indexer: @unchecked Sendable {

    public struct Options: Sendable {
        public var maxReadBytes: Int64 = 8 * 1024 * 1024
        public var hashCandidatesOnly = true
        public var maxFiles: Int? = nil
        public init() {}
    }

    public struct Progress: Sendable {
        public let processed: Int
        public let total: Int
        public let lastPath: String
    }

    private let broker: SourceBroker
    private let catalog: Catalog
    private let scheduler: Scheduler
    private let evidence: EvidenceExtractor
    private let classifier = RuleBasedClassifier()
    private let options: Options

    public init(broker: SourceBroker, catalog: Catalog, scheduler: Scheduler, options: Options = .init()) {
        self.broker = broker
        self.catalog = catalog
        self.scheduler = scheduler
        self.options = options
        self.evidence = EvidenceExtractor(broker: broker)
    }

    /// Index a security-scoped root folder. Returns number of files processed.
    @discardableResult
    public func indexRoot(_ root: URL, onProgress: ((Progress) -> Void)? = nil) throws -> Int {
        let items = try SourceBroker.enumerate(root: root)
        var processed = 0
        let total = min(items.count, options.maxFiles ?? Int.max)

        for item in items.prefix(options.maxFiles ?? Int.max) {
            do {
                try indexOne(path: item.path)
            } catch {
                // A per-file failure must never stop the run; record with an
                // opaque ref only — never the path or content.
                try? catalog.recordError(opaqueRef: FileID.workerError(processed + 1),
                                         stage: "index", message: String(describing: error).prefix(200).description)
            }
            processed += 1
            if let onProgress {
                onProgress(Progress(processed: processed, total: total,
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
        return processed
    }

    /// Index a single file end-to-end with race detection.
    public func indexOne(path: String) throws {
        // 1. Identity BEFORE processing.
        guard let ident = try? broker.identity(at: path) else { return }

        if ident.isSymlink {
            // Plan §22: index the link itself as metadata. Never open it.
            let id = FileID.make(identity: ident)
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "indexed")
            return
        }

        // Cloud placeholders are recorded but never hydrated (plan §24).
        if EvidenceExtractor.isCloudPlaceholder(at: path) {
            let id = FileID.make(identity: ident)
            try catalog.upsertFile(identity: ident, id: id)
            try catalog.setStatus(fileID: id, status: "cloud-placeholder")
            return
        }

        let id = FileID.make(identity: ident)
        try catalog.upsertFile(identity: ident, id: id)

        // 2. Extract bounded evidence + content.
        let ev = evidence.extract(identity: ident)
        var textContent: String? = ev.textSample

        switch ident.kind {
        case .pdf:
            if let pdfText = PDFText.extract(path: path, broker: broker) {
                textContent = String(pdfText.prefix(200_000))
                try? catalog.saveText(fileID: id, body: textContent!, extractor: "pdfkit")
            }
        case .text:
            if let t = textContent {
                try? catalog.saveText(fileID: id, body: t, extractor: "utf8")
            }
        default:
            break
        }

        // 3. Classify (deterministic v1) under MEDIUM slot.
        let classification = try scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent)
        }
        // Contract wall: validate our own output through the same gate an LLM
        // would face. If it fails validation, it is discarded entirely.
        if let validated = ClassifierContract.validate(try classification.jsonData()) {
            try catalog.saveClassification(validated, classifier: "rule-based-v1")
        } else {
            try? catalog.recordError(opaqueRef: id, stage: "classifier", message: "output failed schema validation; discarded")
        }

        // 4. Duplicate detection: size-bucketed candidates only (plan §18).
        try maybeHash(fileID: id, identity: ident)

        // 5. Re-stat IMMEDIATELY before commit; discard on mismatch (plan §21).
        guard let now = try? broker.identity(at: path), ident.stillMatches(now) else {
            try catalog.setStatus(fileID: id, status: "changed-during-index")
            return
        }
        try catalog.setStatus(fileID: id, status: "indexed")
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
    private func maybeHash(fileID: String, identity: FileIdentity) throws {
        guard options.hashCandidatesOnly else { return }
        let sameSize = try catalog.query(
            "SELECT count(*) FROM files WHERE size=? AND id!=?", binds: [.int(identity.size), .text(fileID)]) { $0.int(0) }
        guard (sameSize.first ?? 0) > 0 else { return }
        if let digest = try? DuplicateDetector.sha256(path: identity.path, broker: broker) {
            try? catalog.recordHash(fileID: fileID, size: identity.size, sha256: digest)
        }
    }
}
