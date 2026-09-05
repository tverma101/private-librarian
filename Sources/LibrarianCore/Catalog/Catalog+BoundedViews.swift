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
        roots: [String]? = nil,
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
                -- Indexed-only grouping, matching duplicateFileIDs() and the
                -- dashboard so all duplicate views agree.
                SELECT dhe.size, dhe.sha256 FROM exact_hashes dhe
                JOIN files df ON df.id=dhe.file_id
                WHERE df.status='indexed'
                GROUP BY dhe.size, dhe.sha256 HAVING count(*) > 1
             ) dup ON dup.size=eh.size AND dup.sha256=eh.sha256
            """
            clauses.append("f.status='indexed'")
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

        let scope = scopedRootPredicate(column: "f.path", roots: roots)
        if !scope.sql.isEmpty {
            clauses.append(scope.sql)
            binds.append(contentsOf: scope.binds)
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
        roots: [String]? = nil,
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
        let scope = scopedRootPredicate(column: "f_scope.path", roots: roots)
        let scopeJoin = scope.sql.isEmpty
            ? ""
            : " JOIN similarity_cluster_members scm_scope ON scm_scope.cluster_id=similarity_clusters.id JOIN files f_scope ON f_scope.id=scm_scope.file_id"
        if !scope.sql.isEmpty {
            clauses.append(scope.sql)
            binds.append(contentsOf: scope.binds)
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        binds.append(.int(Int64(pageLimit)))

        let rows = try query("""
            SELECT DISTINCT similarity_clusters.id,similarity_clusters.family_id,
                   similarity_clusters.relation,similarity_clusters.representative,
                   similarity_clusters.confidence,similarity_clusters.reason
            FROM similarity_clusters\(scopeJoin)\(whereClause)
            ORDER BY similarity_clusters.id
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
        var memberBinds = rows.map { SQLValue.text($0.id) }
        var memberSQL = """
            SELECT scm.cluster_id,scm.file_id
            FROM similarity_cluster_members scm
            """
        var memberClauses = ["scm.cluster_id IN (\(placeholders))"]
        let memberScope = scopedRootPredicate(column: "f_scope.path", roots: roots)
        if !memberScope.sql.isEmpty {
            memberSQL += " JOIN files f_scope ON f_scope.id=scm.file_id"
            memberClauses.append(memberScope.sql)
            memberBinds.append(contentsOf: memberScope.binds)
        }
        memberSQL += " WHERE " + memberClauses.joined(separator: " AND ") + " ORDER BY scm.cluster_id,scm.file_id"
        let members = try query(memberSQL, binds: memberBinds) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        var membersByCluster: [String: [String]] = [:]
        for (clusterID, fileID) in members {
            membersByCluster[clusterID, default: []].append(fileID)
        }
        return rows.compactMap { row in
            let scopedMembers = membersByCluster[row.id] ?? []
            guard scopedMembers.count >= 2 else { return nil }
            return SimilarityCluster(id: row.id,
                                     members: scopedMembers,
                                     representative: scopedMembers.contains(row.representative)
                                         ? row.representative : scopedMembers[0],
                                     relation: row.relation,
                                     familyID: row.family,
                                     confidence: row.confidence,
                                     reason: row.reason.isEmpty ? nil : row.reason)
        }
    }
}
