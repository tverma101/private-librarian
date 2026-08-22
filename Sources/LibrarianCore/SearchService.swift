import Accelerate
import Foundation
import Vision

/// Search modes (plan §29). v1 ships exact (FTS5) + filters; semantic and
/// visual similarity hooks exist but require models provisioned separately.
public struct SearchService: Sendable {

    let catalog: Catalog

    public init(catalog: Catalog) { self.catalog = catalog }

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
        var hits = try catalog.searchExact(q)
        for f in filters {
            switch f {
            case .kind(let k):
                hits = try hits.filter { hit in
                    (try catalog.fileKind(id: hit.fileID)) == k
                }
            case .lowConfidence:
                hits = try hits.filter { hit in
                    (try catalog.confidence(forFile: hit.fileID)).map { $0 < 0.45 } ?? false
                }
            default:
                break // category/date/duplicate filters land with UI in Stage C+
            }
        }
        return hits
    }

    /// Visual similarity: rank indexed images by Vision feature-print distance to the query image.
    /// Uses the on-device VNGenerateImageFeaturePrint embedding stored in visual_features.
    public func visualSearch(nearImagePath path: String, broker: SourceBroker, limit: Int = 20, threshold: Float = 0.5) throws -> [(fileID: String, path: String, distance: Float)] {
        guard let data = try? broker.boundedRead(path, limit: VisionImageAnalyzer.maxVisionBytes), !data.isEmpty,
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
        guard let q = LocalModelBridge.embedText(text), !q.data.isEmpty else { return [] }
        let embedRows = try catalog.query(
            "SELECT e.file_id, e.vector, f.path FROM embeddings e JOIN files f ON f.id = e.file_id WHERE e.model=?",
            binds: [.text(LocalModelBridge.Model.miniLMText.rawValue)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data(), r.text(2) ?? "") }
        let chunkRows = (try? catalog.query(
            "SELECT file_id, vector FROM embedding_chunks WHERE model=?",
            binds: [.text(LocalModelBridge.Model.miniLMText.rawValue)]
        ) { r in (r.text(0) ?? "", r.blob(1) ?? Data()) }) ?? []
        // Join path for chunks via lookup so we still pay one files join for embedRows.
        let pathByID: [String: String] = Dictionary(uniqueKeysWithValues: embedRows.map { ($0.0, $0.2) })
        var best: [String: (score: Float, path: String)] = [:]
        for (fid, blob, path) in embedRows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim < threshold { continue }
            if let cur = best[fid], cur.score >= sim { continue }
            best[fid] = (sim, path)
        }
        for (fid, blob) in chunkRows {
            guard let sim = LocalModelBridge.cosineSimilarity(q.data, blob) else { continue }
            if sim < threshold { continue }
            let path = pathByID[fid] ?? (try? catalog.fileRow(id: fid)?.path) ?? fid
            if let cur = best[fid], cur.score >= sim { continue }
            best[fid] = (sim, path)
        }
        var scored: [(String, String, Float)] = best.map { ($0.key, $0.value.path, $0.value.score) }
        scored.sort { $0.2 > $1.2 }
        return Array(scored.prefix(limit))
    }

    /// Visual similarity via local CLIP embeddings (512-d, cosine) — higher quality than Vision feature-print.
    /// Requires Models/clip-vit-base-patch32 provisioned; otherwise returns [].
    public func clipVisualSearch(nearImagePath path: String, limit: Int = 20, threshold: Float = 0.30) throws -> [(fileID: String, path: String, score: Float)] {
        guard let q = LocalModelBridge.embedImage(at: path), !q.data.isEmpty else { return [] }
        let rows = try catalog.query(
            "SELECT e.file_id, e.vector, f.path FROM embeddings e JOIN files f ON f.id = e.file_id WHERE e.model=?",
            binds: [.text(LocalModelBridge.Model.clipImage.rawValue)]
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
        if LocalModelBridge.isProvisioned(.clipImage) {
            let clip = try clipVisualSearch(nearImagePath: path, limit: limit)
            if !clip.isEmpty { return clip.map { ($0.0, $0.1, $0.2, "clip") } }
        }
        // Fallback to Vision (distance -> score for uniform API: score = 1 - distance)
        let vision = try visualSearch(nearImagePath: path, broker: broker, limit: limit, threshold: 0.5)
        return vision.map { ($0.fileID, $0.path, 1 - $0.distance, "vision") }
    }
}
