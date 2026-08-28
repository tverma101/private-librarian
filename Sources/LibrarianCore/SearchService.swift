import Accelerate
import Foundation
import Vision

/// Search modes (plan §29). v1 ships exact (FTS5) + filters; semantic and
/// visual similarity hooks exist but require models provisioned separately.
public struct SearchService: Sendable {

    let catalog: Catalog
    private let enableLocalEmbeddings: Bool
    public let embeddingProvider: any EmbeddingProvider

    public init(catalog: Catalog, enableLocalEmbeddings: Bool? = nil, embeddingProvider: (any EmbeddingProvider)? = nil) {
        self.catalog = catalog
        let enabled = enableLocalEmbeddings ?? UserDefaults.standard.bool(forKey: "tier2-enabled-v1")
        self.enableLocalEmbeddings = enabled
        if let p = embeddingProvider {
            self.embeddingProvider = p
        } else if enabled, CoreMLMobileCLIPProvider.isAvailable {
            self.embeddingProvider = CoreMLMobileCLIPProvider()
        } else {
            self.embeddingProvider = LocalModelEmbeddingProvider()
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

    /// Visual similarity: rank indexed images by Vision feature-print distance to the query image.
    /// Uses the on-device VNGenerateImageFeaturePrint embedding stored in visual_features.
    public func visualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20, threshold: Float = 0.5) throws -> [(fileID: String, path: String, distance: Float)] {
        guard limit > 0 else { return [] }
        guard let data = try? broker.completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes), !data.isEmpty,
              let fp = VisionImageAnalyzer.featurePrint(data: data) else { return [] }
        let qData = fp.data
        var scored: [(String, String, Float)] = []
        for (fid, blob) in try catalog.allVisualFeatures() {
            guard let row = try catalog.fileRow(id: fid) else { continue }
            guard let dist = VisionImageAnalyzer.distance(qData, blob) else { continue }
            if dist <= threshold { scored.append((fid, row.path, dist)) }
        }
        scored.sort { $0.2 < $1.2 }
        return Array(scored.prefix(limit))
    }

    // MARK: - Tier-2 local embeddings (CLIP / MiniLM, still offline — no network)

    /// Semantic text search over local MiniLM embeddings (384-d, cosine).
    /// Chunk-aware: text can span chunks (score = max over chunks). Requires provisioned model; otherwise [].
    public func semanticSearch(query text: String, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard embeddingProvider.preflight.available,
              let q = embeddingProvider.embedText(text), !q.data.isEmpty else { return [] }
        let embedRows = try catalog.query(
            "SELECT e.file_id, e.vector, f.path FROM embeddings e JOIN files f ON f.id = e.file_id WHERE f.status='indexed' AND e.model=?",
            binds: [.text(embeddingProvider.textModelID)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data(), r.text(2) ?? "") }
        let chunkRows = try catalog.query(
            "SELECT c.file_id, c.vector, f.path FROM embedding_chunks c JOIN files f ON f.id=c.file_id WHERE f.status='indexed' AND c.model=?",
            binds: [.text(embeddingProvider.textModelID)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data(), r.text(2) ?? "") }
        var best: [String: (score: Float, path: String)] = [:]
        for (fid, blob, path) in embedRows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim < threshold { continue }
            if let cur = best[fid], cur.score >= sim { continue }
            best[fid] = (sim, path)
        }
        for (fid, blob, path) in chunkRows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim < threshold { continue }
            if let cur = best[fid], cur.score >= sim { continue }
            best[fid] = (sim, path)
        }
        var scored: [(String, String, Float)] = best.map { ($0.key, $0.value.path, $0.value.score) }
        scored.sort { $0.2 > $1.2 }
        return Array(scored.prefix(limit))
    }

    /// Visual similarity via local CLIP embeddings (512-d, cosine) — higher quality than Vision feature-print.
    /// Requires Models/clip-vit-base-patch32 provisioned; otherwise returns [].
    public func clipVisualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard let bytes = try? broker.completeSnapshot(path, maxBytes: VisionImageAnalyzer.maxImageContainerBytes),
              embeddingProvider.preflight.available,
              let q = embeddingProvider.embedImageBytes(bytes), !q.data.isEmpty else { return [] }
        let rows = try catalog.query(
            "SELECT e.file_id, e.vector, f.path FROM embeddings e JOIN files f ON f.id = e.file_id WHERE f.status='indexed' AND e.model=?",
            binds: [.text(embeddingProvider.imageModelID)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data(), r.text(2) ?? "") }
        var scored: [(String, String, Float)] = []
        for (fid, blob, path) in rows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim >= threshold { scored.append((fid, path, sim)) }
        }
        scored.sort { $0.2 > $1.2 }
        return Array(scored.prefix(limit))
    }

    /// Compatibility wrapper for callers that do not provide a broker.
    /// It still uses SourceBroker's complete snapshot policy.
    public func clipVisualSearch(nearImagePath path: String, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        try clipVisualSearch(nearImagePath: path, broker: SourceBroker(), limit: limit, threshold: threshold)
    }

    /// Cross-modal text → image search: encode the text query with CLIP's text encoder
    /// (same 512-d joint space as image CLIP) and rank indexed CLIP image embeddings by cosine.
    /// Requires Models/clip-vit-base-patch32 provisioned; otherwise returns [].
    public func clipTextToImageSearch(query text: String, limit: Int = 20, threshold: Float = 0.22) throws -> [(fileID: String, path: String, score: Float)] {
        guard limit > 0 else { return [] }
        guard enableLocalEmbeddings else { return [] }
        guard embeddingProvider.preflight.available,
              let q = embeddingProvider.embedJointText(text), !q.data.isEmpty else { return [] }
        let rows = try catalog.query(
            "SELECT e.file_id, e.vector, f.path FROM embeddings e JOIN files f ON f.id = e.file_id WHERE f.status='indexed' AND e.model=?",
            binds: [.text(embeddingProvider.imageModelID)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data(), r.text(2) ?? "") }
        var scored: [(String, String, Float)] = []
        for (fid, blob, path) in rows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim >= threshold { scored.append((fid, path, sim)) }
        }
        scored.sort { $0.2 > $1.2 }
        return Array(scored.prefix(limit))
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
