import Foundation

extension Catalog {
    /// SQL-side file page used by large-library UI views. Filtering happens
    /// before rows cross into Swift so a million-file catalog does not become
    /// a million `FileSummary` objects just to render the first screen.
    public func boundedFileSummaries(
        categoryPrefix: String? = nil,
        status: String? = nil,
        kinds: [FileKind] = [],
        duplicateOnly: Bool = false,
        afterPath: String? = nil,
        limit: Int = 200
    ) throws -> [FileSummary] {
        let pageLimit = max(0, min(limit, 1_000))
        guard pageLimit > 0 else { return [] }

        var withClause = ""
        var joins = ""
        var clauses = ["f.status != 'unscoped'"]
        var binds: [SQLValue] = []

        if let categoryPrefix {
            withClause = """
            WITH RECURSIVE category_paths(id, path) AS (
                SELECT id, name FROM virtual_categories WHERE parent_id IS NULL
                UNION ALL
                SELECT c.id, category_paths.path || '/' || c.name
                FROM virtual_categories c JOIN category_paths ON c.parent_id = category_paths.id
            )
            """
            joins += " JOIN category_membership cm ON cm.file_id=f.id JOIN category_paths cp ON cp.id=cm.category_id"
            clauses.append("(cp.path=? OR substr(cp.path,1,length(?) + 1)=? || '/')")
            binds.append(contentsOf: [.text(categoryPrefix), .text(categoryPrefix), .text(categoryPrefix)])
        }

        if duplicateOnly {
            joins += """
             JOIN exact_hashes eh ON eh.file_id=f.id
             JOIN (
                SELECT size, sha256 FROM exact_hashes
                GROUP BY size, sha256 HAVING count(*) > 1
             ) dup ON dup.size=eh.size AND dup.sha256=eh.sha256
            """
            clauses.append("f.status NOT IN ('missing','unscoped')")
        }

        if let status {
            clauses.append("f.status=?")
            binds.append(.text(status))
        }

        if !kinds.isEmpty {
            clauses.append("f.kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))")
            binds.append(contentsOf: kinds.map { .text($0.rawValue) })
        }

        if let afterPath {
            clauses.append("f.path>?")
            binds.append(.text(afterPath))
        }

        binds.append(.int(Int64(pageLimit)))
        let sql = """
        \(withClause)
        SELECT DISTINCT f.id, f.path, f.kind, f.status, c.confidence
        FROM files f
        LEFT JOIN classifications c ON c.file_id=f.id
        \(joins)
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY f.path
        LIMIT ?
        """
        return try query(sql, binds: binds) { row in
            FileSummary(id: row.text(0) ?? "", path: row.text(1) ?? "",
                        kind: row.text(2) ?? "", status: row.text(3) ?? "",
                        confidence: row.isNull(4) ? nil : row.real(4))
        }
    }

    /// Similarity map page. Only members of the selected cluster page are
    /// loaded; the full cluster-members table never needs to enter Swift.
    public func boundedSimilarityClusters(
        relation: SimilarityRelation? = nil,
        afterID: String? = nil,
        limit: Int = 200
    ) throws -> [SimilarityCluster] {
        let pageLimit = max(0, min(limit, 1_000))
        guard pageLimit > 0 else { return [] }

        var clauses: [String] = []
        var binds: [SQLValue] = []
        if let relation {
            clauses.append("relation=?")
            binds.append(.text(relation.rawValue))
        }
        if let afterID {
            clauses.append("id>?")
            binds.append(.text(afterID))
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        binds.append(.int(Int64(pageLimit)))

        let rows = try query("""
            SELECT id,family_id,relation,representative,confidence,reason
            FROM similarity_clusters\(whereClause)
            ORDER BY id
            LIMIT ?
            """, binds: binds) { row in
            (id: row.text(0) ?? "",
             family: row.text(1) ?? "",
             relation: SimilarityRelation(rawValue: row.text(2) ?? "") ?? .nearDuplicate,
             representative: row.text(3) ?? "",
             confidence: Float(row.real(4)),
             reason: row.text(5) ?? "")
        }
        guard !rows.isEmpty else { return [] }

        let placeholders = Array(repeating: "?", count: rows.count).joined(separator: ",")
        let memberBinds = rows.map { SQLValue.text($0.id) }
        let members = try query("""
            SELECT cluster_id,file_id
            FROM similarity_cluster_members
            WHERE cluster_id IN (\(placeholders))
            ORDER BY cluster_id,file_id
            """, binds: memberBinds) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        var membersByCluster: [String: [String]] = [:]
        for (clusterID, fileID) in members {
            membersByCluster[clusterID, default: []].append(fileID)
        }
        return rows.map { row in
            SimilarityCluster(id: row.id,
                              members: membersByCluster[row.id] ?? [],
                              representative: row.representative,
                              relation: row.relation,
                              familyID: row.family,
                              confidence: row.confidence,
                              reason: row.reason.isEmpty ? nil : row.reason)
        }
    }
}
