import Accelerate
import Foundation
import Vision

/// Search modes (plan §29). v1 ships exact (FTS5) + filters; semantic and
/// visual similarity hooks exist but require models provisioned separately.
public struct SearchService: Sendable {

    let catalog: Catalog
    private let enableLocalEmbeddings: Bool
    public let localModelProfile: LocalModelProfile
    public let embeddingProvider: any EmbeddingProvider
    private static let vectorBatchSize: Int64 = 512

    public init(catalog: Catalog, enableLocalEmbeddings: Bool? = nil,
                localModelProfile: LocalModelProfile = .fast,
                embeddingProviderKind: String? = nil,
                embeddingProvider: (any EmbeddingProvider)? = nil) {
        self.catalog = catalog
        let enabled = enableLocalEmbeddings ?? UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        self.enableLocalEmbeddings = enabled
        self.localModelProfile = localModelProfile
        if let p = embeddingProvider {
            self.embeddingProvider = p
        } else {
            self.embeddingProvider = LocalEmbeddingProviderSelection.make(
                enabled: enabled,
                requestedProviderKind: embeddingProviderKind)
        }
    }

    public enum Filter: Sendable {
        case kind(String)
        case category(String)
        case before(Date)
        case after(Date)
        case duplicatesOnly
        case lowConfidence
    }

    /// Exact search with optional filters.
    public func search(_ q: String, filters: [Filter] = []) throws -> [Catalog.SearchHit] {
        guard !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var hits = try catalog.searchExact(q)
        for f in filters {
            switch f {
            case .kind(let k):
                let ids = Set(try catalog.query(
                    "SELECT id FROM files WHERE status='indexed' AND kind=?",
                    binds: [.text(k)]) { $0.text(0) ?? "" })
                hits = hits.filter { ids.contains($0.fileID) }
            case .lowConfidence:
                let ids = Set(try catalog.query("""
                    SELECT f.id
                    FROM files f JOIN classifications c ON c.file_id=f.id
                    WHERE f.status='indexed' AND c.confidence < ?
                    """, binds: [.real(0.45)]) { $0.text(0) ?? "" })
                hits = hits.filter { ids.contains($0.fileID) }
            case .category(let category):
                let ids = try catalog.categoryFileIDs(prefix: category)
                hits = hits.filter { ids.contains($0.fileID) }
            case .before(let date):
                let ids = Set(try catalog.allFiles(statuses: ["indexed"])
                    .filter { $0.mtime < date.timeIntervalSince1970 }
                    .map(\.id))
                hits = hits.filter { ids.contains($0.fileID) }
            case .after(let date):
                let ids = Set(try catalog.allFiles(statuses: ["indexed"])
                    .filter { $0.mtime > date.timeIntervalSince1970 }
                    .map(\.id))
                hits = hits.filter { ids.contains($0.fileID) }
            case .duplicatesOnly:
                let ids = try catalog.duplicateFileIDs()
                hits = hits.filter { ids.contains($0.fileID) }
            }
        }
        return hits
    }

    /// Keep only the best `limit` scores seen so far. This is deliberately a
    /// tiny dictionary rather than an array proportional to the catalog size.
    private static func considerHighest(
        fileID: String, path: String, score: Float,
        limit: Int, best: inout [String: (score: Float, path: String)]
    ) {
        if let current = best[fileID] {
            if score > current.score || (score == current.score && path < current.path) {
                best[fileID] = (score, path)
            }
            return
        }
        if best.count < limit {
            best[fileID] = (score, path)
            return
        }
        guard let weakest = best.min(by: {
            if $0.value.score != $1.value.score {
                return $0.value.score < $1.value.score
            }
            // On an equal score, retain the lexically earlier path.
            return $0.value.path > $1.value.path
        }),
              score > weakest.value.score
                || (score == weakest.value.score && path < weakest.value.path) else { return }
        best.removeValue(forKey: weakest.key)
        best[fileID] = (score, path)
    }

    private static func considerLowest(
        fileID: String, path: String, distance: Float,
        limit: Int, best: inout [String: (distance: Float, path: String)]
    ) {
        if let current = best[fileID] {
            if distance < current.distance || (distance == current.distance && path < current.path) {
                best[fileID] = (distance, path)
            }
            return
        }
        if best.count < limit {
            best[fileID] = (distance, path)
            return
        }
        guard let worst = best.max(by: {
            if $0.value.distance != $1.value.distance {
                return $0.value.distance < $1.value.distance
            }
            return $0.value.path < $1.value.path
        }),
              distance < worst.value.distance
                || (distance == worst.value.distance && path < worst.value.path) else { return }
        best.removeValue(forKey: worst.key)
        best[fileID] = (distance, path)
    }

    /// Visual similarity: rank indexed images by Vision feature-print distance to the query image.
    /// Rows are read from SQLCipher in fixed batches and only top-K candidates
    /// are retained, so query memory does not scale with the number of images.
    public func visualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20, threshold: Float = 0.5) throws -> [(fileID: String, path: String, distance: Float)] {
        guard limit > 0 else { return [] }
        guard let data = try? broker.completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes), !data.isEmpty,
              let fp = VisionImageAnalyzer.featurePrint(data: data) else { return [] }
        let qData = fp.data
        var best: [String: (distance: Float, path: String)] = [:]
        var lastRowID: Int64 = 0
        while true {
            let rows = try catalog.query("""
                SELECT CAST(v.rowid AS TEXT), v.file_id, v.featureprint, f.path
                FROM visual_features v JOIN files f ON f.id=v.file_id
                WHERE f.status='indexed' AND v.rowid>?
                ORDER BY v.rowid LIMIT ?
                """, binds: [.int(lastRowID), .int(Self.vectorBatchSize)]) { row in
                    (Int64(row.text(0) ?? "0") ?? 0,
                     row.text(1) ?? "", row.blob(2) ?? Data(), row.text(3) ?? "")
                }
            guard !rows.isEmpty else { break }
            for (rowID, fid, blob, candidatePath) in rows {
                lastRowID = max(lastRowID, rowID)
                guard let dist = VisionImageAnalyzer.distance(qData, blob), dist <= threshold else { continue }
                Self.considerLowest(fileID: fid, path: candidatePath, distance: dist,
                                    limit: limit, best: &best)
            }
            if rows.count < Int(Self.vectorBatchSize) { break }
        }
        return best.map { ($0.key, $0.value.path, $0.value.distance) }
            .sorted { $0.2 != $1.2 ? $0.2 < $1.2 : $0.1 < $1.1 }
    }

    // MARK: - Tier-2 local embeddings (CLIP / MiniLM, still offline — no network)

    private func scoreEmbeddingTable(
        table: String, alias: String, modelID: String, query: Data,
        threshold: Float, limit: Int,
        best: inout [String: (score: Float, path: String)]
    ) throws {
        precondition(table == "embeddings" || table == "embedding_chunks")
        precondition(alias == "e" || alias == "c")
        var lastRowID: Int64 = 0
        while true {
            let rows = try catalog.query("""
                SELECT CAST(\(alias).rowid AS TEXT), \(alias).file_id, \(alias).vector, f.path
                FROM \(table) \(alias) JOIN files f ON f.id=\(alias).file_id
                WHERE f.status='indexed' AND \(alias).model=? AND \(alias).rowid>?
                ORDER BY \(alias).rowid LIMIT ?
                """, binds: [.text(modelID), .int(lastRowID), .int(Self.vectorBatchSize)]) { row in
                    (Int64(row.text(0) ?? "0") ?? 0,
                     row.text(1) ?? "", row.blob(2) ?? Data(), row.text(3) ?? "")
                }
            guard !rows.isEmpty else { break }
            for (rowID, fid, blob, candidatePath) in rows {
                lastRowID = max(lastRowID, rowID)
                guard let sim = LocalModelBridge.cosineSimilarity(query, blob), sim >= threshold else { continue }
                Self.considerHighest(fileID: fid, path: candidatePath, score: sim,
                                     limit: limit, best: &best)
            }
            if rows.count < Int(Self.vectorBatchSize) { break }
        }
    }

    /// Semantic text search over local MiniLM embeddings (384-d, cosine).
    /// Chunk-aware: text can span chunks (score = max over chunks). Both tables
    /// are scanned in fixed batches while only the best K file IDs stay live.
    public func semanticSearch(query text: String, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard embeddingProvider.preflight.available,
              let q = embeddingProvider.embedText(text), !q.data.isEmpty else { return [] }
        var best: [String: (score: Float, path: String)] = [:]
        try scoreEmbeddingTable(table: "embeddings", alias: "e",
                                modelID: embeddingProvider.textModelID,
                                query: q.data, threshold: threshold,
                                limit: limit, best: &best)
        try scoreEmbeddingTable(table: "embedding_chunks", alias: "c",
                                modelID: embeddingProvider.textModelID,
                                query: q.data, threshold: threshold,
                                limit: limit, best: &best)
        return best.map { ($0.key, $0.value.path, $0.value.score) }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 < $1.1 }
    }

    private func scoreImageEmbeddingTable(
        query: Data, modelID: String, threshold: Float, limit: Int
    ) throws -> [(fileID: String, path: String, score: Float)] {
        var best: [String: (score: Float, path: String)] = [:]
        try scoreEmbeddingTable(table: "embeddings", alias: "e", modelID: modelID,
                                query: query, threshold: threshold,
                                limit: limit, best: &best)
        return best.map { ($0.key, $0.value.path, $0.value.score) }
            .sorted { $0.2 != $1.2 ? $0.2 > $1.2 : $0.1 < $1.1 }
    }

    /// Visual similarity via local CLIP embeddings (512-d, cosine) — higher quality than Vision feature-print.
    /// Requires Models/clip-vit-base-patch32 provisioned; otherwise returns [].
    public func clipVisualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard let bytes = try? broker.completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes),
              embeddingProvider.preflight.available,
              let q = embeddingProvider.embedImageBytes(bytes), !q.data.isEmpty else { return [] }
        return try scoreImageEmbeddingTable(query: q.data, modelID: embeddingProvider.imageModelID,
                                            threshold: threshold, limit: limit)
    }

    /// Compatibility wrapper for callers that do not provide a broker.
    /// It still uses SourceBroker's complete snapshot policy.
    public func clipVisualSearch(nearImagePath path: String, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        try clipVisualSearch(nearImagePath: path, broker: SourceBroker(), limit: limit, threshold: threshold)
    }

    /// Cross-modal text → image search: encode the text query with CLIP's text encoder
    /// (same 512-d joint space as image vectors) and rank indexed CLIP image embeddings by cosine.
    public func clipTextToImageSearch(query text: String, limit: Int = 20, threshold: Float = 0.22) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard embeddingProvider.preflight.available,
              let q = embeddingProvider.embedJointText(text), !q.data.isEmpty else { return [] }
        return try scoreImageEmbeddingTable(query: q.data, modelID: embeddingProvider.imageModelID,
                                            threshold: threshold, limit: limit)
    }

    /// Unified visual search: prefers CLIP when provisioned, falls back to Vision feature-print.
    public func bestVisualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20) throws -> [(fileID: String, path: String, score: Float, source: String)] {
        guard limit > 0 else { return [] }
        if enableLocalEmbeddings, embeddingProvider.preflight.available {
            let clip = try clipVisualSearch(nearImagePath: path, broker: broker, limit: limit)
            if !clip.isEmpty { return clip.map { ($0.0, $0.1, $0.2, "clip") } }
        }
        // Fallback to Vision (distance -> score for uniform API: score = 1 - distance)
        let vision = try visualSearch(nearImagePath: path, broker: broker, limit: limit, threshold: 0.5)
        return vision.map { ($0.fileID, $0.path, 1 - $0.distance, "vision") }
    }
}
