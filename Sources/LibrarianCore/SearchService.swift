import Foundation

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
}
