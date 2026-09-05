import Foundation

/// Aggregate semantic state for one authorized root. This deliberately stores
/// counts and a small kind histogram rather than concatenating the source tree
/// or retaining every per-file representation in memory.
public struct ProjectSemanticSummary: Sendable, Equatable, Identifiable {
    public let root: String
    public let complete: Bool
    public let fileCount: Int
    public let indexedFileCount: Int
    public let textFileCount: Int
    public let embeddingFileCount: Int
    public let chunkRowCount: Int
    public let vectorBytes: Int64
    public let kindCounts: [String: Int]
    public let summary: String
    public let updated: Double

    public var id: String { root }
}

public struct SemanticStorageMetrics: Sendable, Equatable {
    public let embeddingRows: Int
    public let embeddingFiles: Int
    public let maxEmbeddingsPerFile: Int
    public let embeddingBytes: Int64
    public let chunkRows: Int
    public let chunkFiles: Int
    public let maxChunksPerFile: Int
    public let chunkBytes: Int64
    public let databaseBytes: Int64

    public var totalVectorBytes: Int64 { embeddingBytes + chunkBytes }
}

extension Catalog {
    /// Rebuild one root's aggregate semantic summary using SQL aggregates.
    /// `complete == false` is retained as an honest partial/cancelled marker;
    /// callers never mistake a partial scan for a complete project snapshot.
    @discardableResult
    public func refreshProjectSemanticSummary(
        root: String,
        complete: Bool
    ) throws -> ProjectSemanticSummary {
        let normalizedRoot = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        let descendantPrefix = normalizedRoot == "/" ? "/" : normalizedRoot + "/"
        let aggregateRow = try query("""
            SELECT
                COUNT(*),
                COALESCE(SUM(CASE WHEN f.status='indexed' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN f.kind='text' THEN 1 ELSE 0 END), 0),
                COALESCE(SUM(CASE WHEN EXISTS(
                    SELECT 1 FROM embeddings e WHERE e.file_id=f.id
                ) THEN 1 ELSE 0 END), 0)
            FROM files f
            WHERE f.status!='unscoped'
              AND (f.path=? OR substr(f.path, 1, length(?))=?)
            """, binds: [.text(normalizedRoot), .text(descendantPrefix), .text(descendantPrefix)]) { row in
                (Int(row.int(0)), Int(row.int(1)), Int(row.int(2)), Int(row.int(3)))
            }.first
        let fileCount = aggregateRow?.0 ?? 0
        let indexedFileCount = aggregateRow?.1 ?? 0
        let textFileCount = aggregateRow?.2 ?? 0
        let embeddingFileCount = aggregateRow?.3 ?? 0

        let vectorAggregate = try query("""
            SELECT
                COUNT(*),
                COALESCE(SUM(length(e.vector)), 0)
            FROM embeddings e
            JOIN files f ON f.id=e.file_id
            WHERE f.status!='unscoped'
              AND (f.path=? OR substr(f.path, 1, length(?))=?)
            """, binds: [.text(normalizedRoot), .text(descendantPrefix), .text(descendantPrefix)]) { row in
                (Int(row.int(0)), row.int(1))
            }.first ?? (0, 0)
        let chunkAggregate = try query("""
            SELECT
                COUNT(*),
                COALESCE(SUM(length(c.vector)), 0)
            FROM embedding_chunks c
            JOIN files f ON f.id=c.file_id
            WHERE f.status!='unscoped'
              AND (f.path=? OR substr(f.path, 1, length(?))=?)
            """, binds: [.text(normalizedRoot), .text(descendantPrefix), .text(descendantPrefix)]) { row in
                (Int(row.int(0)), row.int(1))
            }.first ?? (0, 0)

        let kindRows = try query("""
            SELECT f.kind, COUNT(*)
            FROM files f
            WHERE f.status!='unscoped'
              AND (f.path=? OR substr(f.path, 1, length(?))=?)
            GROUP BY f.kind
            ORDER BY COUNT(*) DESC, f.kind
            LIMIT 16
            """, binds: [.text(normalizedRoot), .text(descendantPrefix), .text(descendantPrefix)]) { row in
                (row.text(0) ?? "other", Int(row.int(1)))
            }
        let kindCounts = Dictionary(uniqueKeysWithValues: kindRows)
        let kindText = kindRows.map { "\($0.0)=\($0.1)" }.joined(separator: ", ")
        let label = (normalizedRoot as NSString).lastPathComponent.isEmpty
            ? normalizedRoot : (normalizedRoot as NSString).lastPathComponent
        var summaryText = "Project \(label): \(fileCount) cataloged, "
        summaryText += "\(indexedFileCount) indexed, \(textFileCount) text; "
        summaryText += "kinds [\(kindText.isEmpty ? "none" : kindText)]; "
        summaryText += "semantic vectors \(vectorAggregate.0) + \(chunkAggregate.0) chunks "
        summaryText += "(\(vectorAggregate.1 + chunkAggregate.1) bytes); "
        summaryText += complete ? "status complete" : "status partial (scan incomplete)"
        let now = Date().timeIntervalSince1970
        let kindJSON = try JSONSerialization.data(
            withJSONObject: kindCounts, options: [.sortedKeys])
        let kindJSONText = String(data: kindJSON, encoding: .utf8) ?? "{}"

        try run("""
            INSERT INTO project_summaries(
                root,complete,file_count,indexed_file_count,text_file_count,
                embedding_file_count,chunk_row_count,vector_bytes,
                kind_counts_json,summary,updated
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(root) DO UPDATE SET
                complete=excluded.complete,
                file_count=excluded.file_count,
                indexed_file_count=excluded.indexed_file_count,
                text_file_count=excluded.text_file_count,
                embedding_file_count=excluded.embedding_file_count,
                chunk_row_count=excluded.chunk_row_count,
                vector_bytes=excluded.vector_bytes,
                kind_counts_json=excluded.kind_counts_json,
                summary=excluded.summary,
                updated=excluded.updated
            """, binds: [
                .text(normalizedRoot), .int(complete ? 1 : 0),
                .int(Int64(fileCount)), .int(Int64(indexedFileCount)),
                .int(Int64(textFileCount)), .int(Int64(embeddingFileCount)),
                .int(Int64(chunkAggregate.0)), .int(vectorAggregate.1 + chunkAggregate.1),
                .text(kindJSONText), .text(summaryText), .real(now)
            ])

        return ProjectSemanticSummary(
            root: normalizedRoot, complete: complete,
            fileCount: fileCount,
            indexedFileCount: indexedFileCount,
            textFileCount: textFileCount,
            embeddingFileCount: embeddingFileCount,
            chunkRowCount: chunkAggregate.0,
            vectorBytes: vectorAggregate.1 + chunkAggregate.1,
            kindCounts: kindCounts, summary: summaryText, updated: now)
    }

    public func projectSemanticSummaries(limit: Int = 128,
                                         roots: [String]? = nil) throws -> [ProjectSemanticSummary] {
        let scope = scopedRootPredicate(column: "root", roots: roots)
        let whereClause = scope.sql.isEmpty ? "" : " WHERE \(scope.sql)"
        var binds = scope.binds
        binds.append(.int(Int64(max(1, min(limit, 1_024)))))
        let rows = try query("""
            SELECT root,complete,file_count,indexed_file_count,text_file_count,
                   embedding_file_count,chunk_row_count,vector_bytes,
                   kind_counts_json,summary,updated
            FROM project_summaries
            \(whereClause)
            ORDER BY root
            LIMIT ?
            """, binds: binds) { row in
                let kindJSON = row.text(8) ?? "{}"
                let kindData = kindJSON.data(using: .utf8)
                let kindCounts: [String: Int]
                if let kindData,
                   let object = try? JSONSerialization.jsonObject(with: kindData),
                   let decoded = object as? [String: Int] {
                    kindCounts = decoded
                } else {
                    kindCounts = [:]
                }
                return ProjectSemanticSummary(
                    root: row.text(0) ?? "",
                    complete: row.int(1) != 0,
                    fileCount: Int(row.int(2)),
                    indexedFileCount: Int(row.int(3)),
                    textFileCount: Int(row.int(4)),
                    embeddingFileCount: Int(row.int(5)),
                    chunkRowCount: Int(row.int(6)),
                    vectorBytes: row.int(7),
                    kindCounts: kindCounts,
                    summary: row.text(9) ?? "",
                    updated: row.real(10))
            }
        return rows
    }

    /// Explicit storage metrics used by scale tests and release diagnostics.
    /// All vector aggregates stay in SQL; only the small metric tuple crosses
    /// into Swift.
    public func semanticStorageMetrics() throws -> SemanticStorageMetrics {
        let embeddings = try query("""
            SELECT COUNT(*), COUNT(DISTINCT file_id), COALESCE(SUM(length(vector)),0)
            FROM embeddings
            """) { row in (Int(row.int(0)), Int(row.int(1)), row.int(2)) }.first ?? (0, 0, 0)
        let maxEmbeddings = try query("""
            SELECT COALESCE(MAX(n),0) FROM (
                SELECT file_id, COUNT(*) AS n FROM embeddings GROUP BY file_id
            )
            """) { row in Int(row.int(0)) }.first ?? 0
        let chunks = try query("""
            SELECT COUNT(*), COUNT(DISTINCT file_id), COALESCE(SUM(length(vector)),0)
            FROM embedding_chunks
            """) { row in (Int(row.int(0)), Int(row.int(1)), row.int(2)) }.first ?? (0, 0, 0)
        let maxChunks = try query("""
            SELECT COALESCE(MAX(n),0) FROM (
                SELECT file_id, COUNT(*) AS n FROM embedding_chunks GROUP BY file_id
            )
            """) { row in Int(row.int(0)) }.first ?? 0
        let databaseBytes: Int64 = {
            let main = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
            let wal = (try? FileManager.default.attributesOfItem(atPath: path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
            return main + wal
        }()
        return SemanticStorageMetrics(
            embeddingRows: embeddings.0, embeddingFiles: embeddings.1,
            maxEmbeddingsPerFile: maxEmbeddings, embeddingBytes: embeddings.2,
            chunkRows: chunks.0, chunkFiles: chunks.1,
            maxChunksPerFile: maxChunks, chunkBytes: chunks.2,
            databaseBytes: databaseBytes)
    }
}
