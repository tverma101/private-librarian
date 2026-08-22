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
}
