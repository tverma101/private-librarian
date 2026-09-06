import Foundation

public extension Catalog {
    /// Build bounded, read-only semantic context for one file from facts that
    /// are already in the encrypted catalog. This is the folder-population and
    /// relationship layer: vague folder names are irrelevant; classified peers
    /// and semantic clusters provide the evidence instead.
    func semanticResolutionContext(forFileID fileID: String,
                                   siblingLimit: Int = 32,
                                   clusterPeerLimit: Int = 48) throws -> SemanticResolutionContext {
        let target = try query("SELECT path FROM files WHERE id=? AND status!='unscoped' LIMIT 1",
                               binds: [.text(fileID)]) { $0.text(0) ?? "" }.first
        guard let target, !target.isEmpty else { return .empty }

        var candidates: [SemanticContextCandidate] = []
        let parent = (target as NSString).deletingLastPathComponent
        let prefix = parent == "/" ? "/" : parent + "/"
        let siblingFetch = max(8, min(256, siblingLimit * 4))

        // SQLite has no portable dirname() here. Prefix-bound the query, then
        // enforce direct-parent equality in Swift so nested descendants cannot
        // impersonate siblings.
        let siblingRows = try query("""
            SELECT f.path, c.categories_json, c.confidence
            FROM files f
            JOIN classifications c ON c.file_id=f.id
            WHERE f.id<>? AND f.status='indexed'
              AND substr(f.path,1,length(?))=?
            ORDER BY c.confidence DESC, f.path
            LIMIT ?
            """, binds: [.text(fileID), .text(prefix), .text(prefix), .int(Int64(siblingFetch))]) { row in
                (row.text(0) ?? "", row.text(1) ?? "[]", row.real(2))
            }

        var acceptedSiblings = 0
        for row in siblingRows {
            guard acceptedSiblings < max(0, siblingLimit),
                  (row.0 as NSString).deletingLastPathComponent == parent else { continue }
            acceptedSiblings += 1
            for category in Self.semanticContextCategories(fromJSON: row.1) {
                candidates.append(SemanticContextCandidate(
                    category: category,
                    confidence: min(0.95, row.2),
                    source: .sibling))
            }
        }

        // Only semantic similarity may teach destination context. Near-duplicate
        // families remain relationship-only and can never vote a file into a
        // Finder category.
        let clusterRows = try query("""
            SELECT c.categories_json, c.confidence, s.confidence
            FROM similarity_cluster_members mine
            JOIN similarity_clusters s ON s.id=mine.cluster_id
            JOIN similarity_cluster_members peer ON peer.cluster_id=mine.cluster_id
            JOIN classifications c ON c.file_id=peer.file_id
            WHERE mine.file_id=? AND peer.file_id<>mine.file_id
              AND s.relation='semantic'
            ORDER BY s.confidence DESC, c.confidence DESC
            LIMIT ?
            """, binds: [.text(fileID), .int(Int64(max(0, min(256, clusterPeerLimit))))]) { row in
                (row.text(0) ?? "[]", row.real(1), row.real(2))
            }
        for row in clusterRows {
            let confidence = min(0.97, max(0, min(row.1, row.2)))
            for category in Self.semanticContextCategories(fromJSON: row.0) {
                candidates.append(SemanticContextCandidate(
                    category: category,
                    confidence: confidence,
                    source: .similarityCluster))
            }
        }

        // A direct user correction on this file is authoritative semantic
        // evidence. Cross-file learning remains handled by promoted learned
        // rules; this method never generalizes one correction by itself.
        let corrected = try query("""
            SELECT category, action
            FROM category_overrides
            WHERE file_id=?
            ORDER BY updated DESC
            LIMIT 32
            """, binds: [.text(fileID)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        for (category, action) in corrected where action == ReviewCorrectionAction.addCategory.rawValue {
            guard Self.isUsefulSemanticCategory(category) else { continue }
            candidates.append(SemanticContextCandidate(
                category: category, confidence: 0.99,
                source: .userCorrection))
        }

        return SemanticResolutionContext(candidates: candidates)
    }

    /// Refine an already validated classification using catalog context. This
    /// helper is side-effect free; callers still choose when to persist or plan.
    func semanticallyResolvedClassification(fileID: String) throws -> Classification? {
        let rows = try query("""
            SELECT categories_json, description, confidence, reason_codes_json
            FROM classifications
            WHERE file_id=?
            LIMIT 1
            """, binds: [.text(fileID)]) { row in
                (row.text(0) ?? "[]", row.text(1) ?? "", row.real(2), row.text(3) ?? "[]")
            }
        guard let row = rows.first,
              let categoriesData = row.0.data(using: .utf8),
              let reasonsData = row.3.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: categoriesData),
              let reasons = try? JSONDecoder().decode([String].self, from: reasonsData) else {
            return nil
        }
        let base = Classification(fileID: fileID, categories: categories,
                                  description: row.1, confidence: row.2,
                                  reasonCodes: reasons)
        return SemanticResolver().resolve(
            base: base,
            context: try semanticResolutionContext(forFileID: fileID))
    }

    /// Organization-time semantic pass. It adds only high-confidence inferred
    /// memberships to the in-memory planning view; the catalog classification
    /// is not rewritten and Finder remains untouched. Inferred categories must
    /// already exist in the catalog taxonomy, so context cannot explode the
    /// folder tree or materialize a model-invented destination.
    func semanticOrganizationMemberships(limit: Int = 384,
                                         roots: [String]? = nil) throws -> [(categoryPath: String, fileID: String)] {
        var memberships = try categoryMemberships(roots: roots)
        let existing = Set(memberships.map(\.categoryPath))
        var seen = Set(memberships.map { "\($0.categoryPath)\u{0}\($0.fileID)" })
        let boundedLimit = max(1, min(2_048, limit))

        // Context is useful primarily for generic/ambiguous files. Keep this a
        // bounded pass rather than walking every library item during every UI
        // refresh. Explicit Review items are included regardless of raw score.
        let scope = scopedRootPredicate(column: "f.path", roots: roots)
        var clauses = ["f.status='indexed'", "(c.confidence < 0.80 OR c.categories_json LIKE '%\"Review\"%')"]
        if !scope.sql.isEmpty { clauses.append(scope.sql) }
        var binds = scope.binds
        binds.append(.int(Int64(boundedLimit)))
        let candidateIDs = try query("""
            SELECT c.file_id
            FROM classifications c
            JOIN files f ON f.id=c.file_id
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY c.confidence ASC, c.file_id
            LIMIT ?
            """, binds: binds) { $0.text(0) ?? "" }

        for fileID in candidateIDs where !fileID.isEmpty {
            guard let resolved = try semanticallyResolvedClassification(fileID: fileID),
                  resolved.confidence >= 0.80,
                  !resolved.categories.contains("Review") else { continue }
            for category in resolved.categories where Self.isUsefulSemanticCategory(category) {
                // Taxonomy firewall: only categories already proven to exist in
                // this scoped library can become contextual planning memberships.
                guard existing.contains(category) else { continue }
                let key = "\(category)\u{0}\(fileID)"
                guard seen.insert(key).inserted else { continue }
                memberships.append((categoryPath: category, fileID: fileID))
            }
        }
        return memberships
    }

    private static func semanticContextCategories(fromJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let categories = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return categories.filter(isUsefulSemanticCategory)
    }

    private static func isUsefulSemanticCategory(_ category: String) -> Bool {
        let generic: Set<String> = [
            "Image", "Audio", "Video", "Documents/PDF", "Documents/Text", "Documents/Office",
            "Archives", "DiskImages", "Applications", "Packages", "Links", "Review", "School"
        ]
        guard !generic.contains(category), category.count <= 64, !category.contains("..") else { return false }
        let punctuation: Set<Character> = [" ", "/", ".", "_", "-"]
        return !category.isEmpty
            && category.allSatisfy { $0.isLetter || $0.isNumber || punctuation.contains($0) }
    }
}
