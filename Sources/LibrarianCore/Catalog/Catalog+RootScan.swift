import Foundation

extension Catalog {
    public struct RootScanCandidate: Sendable, Equatable {
        public let id: String
        public let path: String
    }

    /// Add the scan marker lazily so old catalogs upgrade without a large
    /// migration or an in-memory set containing every discovered pathname.
    private func ensureRootScanGenerationColumn() throws {
        let present = (try? query(
            "SELECT 1 FROM pragma_table_info('files') WHERE name='last_seen_scan'"
        ) { _ in 1 }.first) != nil
        if !present {
            do {
                try run("ALTER TABLE files ADD COLUMN last_seen_scan INTEGER")
            } catch let error as CatalogError {
                if case .execFailed(let message) = error,
                   message.contains("duplicate column") {
                    // Another catalog opener already converged the schema.
                } else {
                    throw error
                }
            }
        }
        try run("INSERT OR IGNORE INTO meta(k,v) VALUES('root_scan_counter','0')")
    }

    /// Allocate a monotonically increasing scan generation inside SQLCipher.
    /// The generation itself is tiny; files are marked in-place as batches are
    /// observed, so memory is independent of total tree size.
    public func beginRootScanGeneration() throws -> Int64 {
        try ensureRootScanGenerationColumn()
        return try transaction {
            let current = try txQuery(
                "SELECT v FROM meta WHERE k='root_scan_counter'"
            ) { Int64($0.text(0) ?? "0") ?? 0 }.first ?? 0
            let next = current == Int64.max ? 1 : current + 1
            if next == 1 && current == Int64.max {
                // Extremely defensive wraparound: clear old markers before
                // reusing generation 1.
                try txRun("UPDATE files SET last_seen_scan=NULL")
            }
            try txRun("UPDATE meta SET v=? WHERE k='root_scan_counter'",
                      binds: [.text(String(next))])
            return next
        }
    }

    public func markRootScanSeen(generation: Int64, paths: [String]) throws {
        guard !paths.isEmpty else { return }
        try transaction {
            for path in paths {
                try txRun("UPDATE files SET last_seen_scan=? WHERE path=?",
                          binds: [.int(generation), .text(path)])
            }
        }
    }

    /// Number of indexed rows currently known under one root, including the
    /// root itself. The app uses this to explain what an analysis run changed
    /// relative to what was already known before it started.
    public func indexedFileCount(under rootPath: String) throws -> Int {
        let normalizedRoot = rootPath.count > 1 && rootPath.hasSuffix("/")
            ? String(rootPath.dropLast()) : rootPath
        let descendantPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        return try query("""
            SELECT COUNT(*) FROM files
            WHERE status='indexed' AND (path=? OR substr(path,1,length(?))=?)
            """, binds: [.text(normalizedRoot), .text(descendantPrefix), .text(descendantPrefix)]) {
            Int($0.int(0))
        }.first ?? 0
    }

    /// Page active catalog rows under one root that were not observed in the
    /// completed scan generation. Callers still prove ENOENT/ENOTDIR through
    /// SourceBroker before changing status; a skipped/unreadable subtree is
    /// therefore never treated as deletion merely because enumeration missed it.
    public func unseenRootScanCandidates(
        generation: Int64,
        root: String,
        afterPath: String? = nil,
        limit: Int = 512
    ) throws -> [RootScanCandidate] {
        let pageLimit = max(1, min(limit, 2_048))
        let normalizedRoot = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        let descendantPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"

        var clauses = [
            "f.status NOT IN ('missing','unscoped')",
            "COALESCE(f.last_seen_scan,-1) != ?",
            "(f.path=? OR substr(f.path,1,length(?))=?)"
        ]
        var binds: [SQLValue] = [
            .int(generation),
            .text(normalizedRoot),
            .text(descendantPrefix), .text(descendantPrefix)
        ]
        if let afterPath {
            clauses.append("f.path>?")
            binds.append(.text(afterPath))
        }
        binds.append(.int(Int64(pageLimit)))

        return try query("""
            SELECT f.id,f.path
            FROM files f
            WHERE \(clauses.joined(separator: " AND "))
            ORDER BY f.path
            LIMIT ?
            """, binds: binds) { row in
            RootScanCandidate(id: row.text(0) ?? "", path: row.text(1) ?? "")
        }
    }
}
