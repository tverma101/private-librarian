import Foundation
import SQLCipher

/// SQLCipher-backed catalog: the ONLY writable store in the system.
/// Key lives in the macOS Keychain (see CatalogKeychain). All content —
/// filenames, OCR, transcripts, embeddings, classifications — is encrypted at
/// rest. FTS5 provides local full-text search inside the encrypted file.
public final class Catalog: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "librarian.catalog.serial")
    private let queueKey = DispatchSpecificKey<Void>()
    public private(set) var path: String

    // MARK: - Errors

    public enum CatalogError: Error, CustomStringConvertible {
        case openFailed(String)
        case execFailed(String)
        case keyRejected

        public var description: String {
            switch self {
            case .openFailed(let m): return "catalog open failed: \(m)"
            case .execFailed(let m): return "catalog exec failed: \(m)"
            case .keyRejected: return "catalog key rejected (wrong key or corrupt db)"
            }
        }
    }

    // MARK: - Lifecycle

    /// Open (creating if needed) an encrypted catalog at `path`.
    /// - Parameter key: raw key material from the Keychain.
    public init(path: String, key: Data) throws {
        queue.setSpecific(key: queueKey, value: ())
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var dbOut: OpaquePointer?
        guard sqlite3_open(path, &dbOut) == SQLITE_OK, let opened = dbOut else {
            let msg = dbOut.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            throw CatalogError.openFailed(msg)
        }
        db = opened

        // Apply the key BEFORE any other statement.
        let rc = key.withUnsafeBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return SQLITE_ERROR }
            return sqlite3_key(opened, base, Int32(buf.count))
        }
        guard rc == SQLITE_OK else { throw CatalogError.keyRejected }

        // Validate the key by forcing a read of the schema; a wrong key must
        // fail here rather than corrupting later writes.
        if sqlite3_exec(opened, "SELECT count(*) FROM sqlite_master;", nil, nil, nil) != SQLITE_OK {
            sqlite3_close(opened)
            db = nil
            throw CatalogError.keyRejected
        }

        try exec("""
        PRAGMA cipher_memory_security = ON;
        PRAGMA journal_mode = WAL;
        PRAGMA synchronous = NORMAL;
        PRAGMA foreign_keys = ON;
        """)
        try migrate()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CatalogError.execFailed(msg)
        }
    }

    // MARK: - Schema (v1)

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS meta (
            k TEXT PRIMARY KEY,
            v TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS files (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            volume_uuid TEXT,
            fs_file_id INTEGER NOT NULL,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            ctime REAL NOT NULL,
            kind TEXT NOT NULL,
            is_symlink INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'pending',
            first_seen REAL NOT NULL,
            last_indexed REAL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_files_path ON files(path);
        CREATE INDEX IF NOT EXISTS idx_files_status ON files(status);

        CREATE TABLE IF NOT EXISTS metadata (
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            k TEXT NOT NULL,
            v TEXT NOT NULL,
            PRIMARY KEY (file_id, k)
        );

        CREATE TABLE IF NOT EXISTS text_content (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            body TEXT NOT NULL,
            extractor TEXT NOT NULL,
            created REAL NOT NULL
        );

        CREATE VIRTUAL TABLE IF NOT EXISTS text_fts USING fts5(
            file_id UNINDEXED, body, tokenize='unicode61'
        );

        CREATE TABLE IF NOT EXISTS classifications (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            categories_json TEXT NOT NULL,
            description TEXT NOT NULL,
            confidence REAL NOT NULL,
            reason_codes_json TEXT NOT NULL,
            classifier TEXT NOT NULL,
            created REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS virtual_categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            parent_id INTEGER REFERENCES virtual_categories(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS category_membership (
            category_id INTEGER NOT NULL REFERENCES virtual_categories(id) ON DELETE CASCADE,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            source TEXT NOT NULL DEFAULT 'classifier',
            PRIMARY KEY (category_id, file_id)
        );

        CREATE TABLE IF NOT EXISTS review_inbox (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            state TEXT NOT NULL DEFAULT 'open',
            reason TEXT NOT NULL,
            created REAL NOT NULL,
            updated REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_review_inbox_state ON review_inbox(state, updated);

        CREATE TABLE IF NOT EXISTS category_overrides (
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            category TEXT NOT NULL,
            action TEXT NOT NULL,
            updated REAL NOT NULL,
            PRIMARY KEY (file_id, category)
        );

        CREATE TABLE IF NOT EXISTS review_corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            category TEXT NOT NULL,
            action TEXT NOT NULL,
            provenance TEXT NOT NULL,
            created REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS organization_edges (
            source_id TEXT NOT NULL,
            target_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            weight REAL NOT NULL,
            PRIMARY KEY (source_id, target_id, relation)
        );
        CREATE INDEX IF NOT EXISTS idx_organization_edges_relation ON organization_edges(relation);

        CREATE TABLE IF NOT EXISTS exact_hashes (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            size INTEGER NOT NULL,
            sha256 BLOB NOT NULL,
            computed REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_hashes_size_sha ON exact_hashes(size, sha256);

        CREATE TABLE IF NOT EXISTS visual_features (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            featureprint BLOB NOT NULL,
            revision TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS embeddings (
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (file_id, model)
        );
        -- Chunked semantic embeddings: one row per text chunk (embedding space chunks/*. same DB contract: key in keychain, never merged across files).
        CREATE TABLE IF NOT EXISTS embedding_chunks (
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            dim INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY (file_id, model, chunk_index)
        );

        CREATE TABLE IF NOT EXISTS processing_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            stage TEXT NOT NULL,
            state TEXT NOT NULL,
            attempts INTEGER NOT NULL DEFAULT 0,
            updated REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS errors (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            opaque_ref TEXT NOT NULL,
            stage TEXT NOT NULL,
            message TEXT NOT NULL,
            created REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS model_provenance (
            model TEXT PRIMARY KEY,
            version TEXT NOT NULL,
            source TEXT NOT NULL,
            license TEXT NOT NULL,
            expected_sha256 TEXT NOT NULL,
            actual_sha256 TEXT,
            verified INTEGER NOT NULL DEFAULT 0,
            loaded_at REAL
        );

        INSERT OR IGNORE INTO virtual_categories(name) VALUES ('Review');
        INSERT OR IGNORE INTO meta(k,v) VALUES ('schema_version','1');
        """)
        // v1→v2: per-file extractor version for incremental skip decisions.
        // Crash-safe: inspect table_info first so a partial migration (ALTER
        // succeeded but UPDATE crashed) does not re-ALTER and fail to open.
        let hasLastExtractor = (try? query("SELECT 1 FROM pragma_table_info('files') WHERE name='last_extractor'") { _ in 1 }.first) != nil
        if !hasLastExtractor {
            // ALTER may still race on a very old file; treat "duplicate column"
            // as success so we converge to v2 regardless.
            do {
                try run("ALTER TABLE files ADD COLUMN last_extractor TEXT")
            } catch let e as CatalogError {
                if case .execFailed(let m) = e, m.contains("duplicate column") { /* already there */ } else { throw e }
            }
        }
        let versionRows = try query("SELECT v FROM meta WHERE k='schema_version'") { $0.text(0) ?? "1" }
        if (versionRows.first ?? "1") == "1" {
            try run("UPDATE meta SET v='2' WHERE k='schema_version'")
        }
    }

    // MARK: - Low-level helpers

    // Raw sqlite execution without queue re-entry — used only inside
    // transaction's already-held queue.sync.
    private func rawExec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw CatalogError.execFailed(msg)
        }
    }

    private func rawRun(_ sql: String, binds: [SQLValue] = []) throws {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CatalogError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        try bind(binds, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw CatalogError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func rawQuery<T>(_ sql: String, binds: [SQLValue] = [], _ row: (Row) throws -> T) throws -> [T] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw CatalogError.execFailed(String(cString: sqlite3_errmsg(db)))
        }
        try bind(binds, to: stmt)
        var out: [T] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(try row(Row(stmt: stmt!)))
        }
        return out
    }

    /// Run a block of catalog writes atomically: all of it lands, or none.
    /// Used by the indexer so a file's text/classification/hash are committed
    /// together, only AFTER the final identity recheck passes.
    /// IMPORTANT: body must use rawRun/rawQuery/execSQL helpers that do NOT
    /// re-enter queue.sync — this method already holds the serial queue.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        try queue.sync {
            do {
                try rawExec("BEGIN IMMEDIATE")
                do {
                    let value = try body()
                    try rawExec("COMMIT")
                    result = .success(value)
                } catch {
                    try? rawExec("ROLLBACK")
                    result = .failure(error)
                }
            } catch {
                try? rawExec("ROLLBACK")
                result = .failure(error)
            }
        }
        switch result! {
        case .success(let v): return v
        case .failure(let e): throw e
        }
    }

    public func run(_ sql: String, binds: [SQLValue] = []) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil { try rawRun(sql, binds: binds); return }
        try queue.sync { try rawRun(sql, binds: binds) }
    }

    public func query<T>(_ sql: String, binds: [SQLValue] = [], _ row: (Row) throws -> T) throws -> [T] {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return try rawQuery(sql, binds: binds, row) }
        return try queue.sync { try rawQuery(sql, binds: binds, row) }
    }

    // Transaction-body helpers — public for indexer use inside transaction.
    public func txRun(_ sql: String, binds: [SQLValue] = []) throws { try rawRun(sql, binds: binds) }
    public func txQuery<T>(_ sql: String, binds: [SQLValue] = [], _ row: (Row) throws -> T) throws -> [T] {
        try rawQuery(sql, binds: binds, row)
    }

    private func bind(_ binds: [SQLValue], to stmt: OpaquePointer?) throws {
        for (i, v) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch v {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case .blob(let d):
                d.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                }
            }
        }
    }

    public enum SQLValue: Sendable {
        case null
        case int(Int64)
        case real(Double)
        case text(String)
        case blob(Data)
    }

    public struct Row {
        let stmt: OpaquePointer
        public func text(_ i: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: c)
        }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        public func real(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        public func blob(_ i: Int32) -> Data? {
            guard let p = sqlite3_column_blob(stmt, i) else { return nil }
            let n = Int(sqlite3_column_bytes(stmt, i))
            return Data(bytes: p, count: n)
        }
        public func isNull(_ i: Int32) -> Bool {
            sqlite3_column_type(stmt, i) == SQLITE_NULL
        }
    }

    // MARK: - File records

    public func upsertFile(identity: FileIdentity, id: String) throws {
        try run("""
        INSERT INTO files(id, path, volume_uuid, fs_file_id, size, mtime, ctime, kind, is_symlink, status, first_seen)
        VALUES(?,?,?,?,?,?,?,?,?, 'pending', ?)
        ON CONFLICT(path) DO UPDATE SET
            volume_uuid=excluded.volume_uuid,
            fs_file_id=excluded.fs_file_id, size=excluded.size,
            mtime=excluded.mtime, ctime=excluded.ctime, kind=excluded.kind,
            is_symlink=excluded.is_symlink
        """, binds: [
            .text(id), .text(identity.path), .text(identity.volumeUUID ?? ""),
            .int(Int64(identity.fileID)), .int(identity.size),
            .real(identity.mtime.timeIntervalSince1970),
            .real(identity.ctime.timeIntervalSince1970),
            .text(identity.kind.rawValue), .int(identity.isSymlink ? 1 : 0),
            .real(Date().timeIntervalSince1970),
        ])
    }

    /// Fingerprint + state needed to decide whether a file needs reprocessing
    /// (ChangeDetection.needsProcessing). Nil = never seen.
    public func storedState(forPath path: String) throws
        -> (size: Int64, mtime: Double, status: String, lastExtractor: String?)? {
        let rows = try query("""
            SELECT size, mtime, status, last_extractor FROM files WHERE path=?
            """, binds: [.text(path)]) { r in
            (r.int(0), r.real(1), r.text(2) ?? "", r.text(3))
        }
        return rows.first
    }

    /// Stamp which extractor/classifier version produced this file's data.
    public func setExtractorVersion(fileID: String, version: String) throws {
        try run("UPDATE files SET last_extractor=? WHERE id=?",
                binds: [.text(version), .text(fileID)])
    }

    public func setStatus(fileID: String, status: String) throws {
        try run("UPDATE files SET status=? WHERE id=?", binds: [.text(status), .text(fileID)])
    }

    public func markMissing(path: String) throws {
        try run("UPDATE files SET status='missing' WHERE path=? AND status!='missing'", binds: [.text(path)])
    }

    public func saveText(fileID: String, body: String, extractor: String) throws {
        try run("DELETE FROM text_fts WHERE file_id=?", binds: [.text(fileID)])
        try run("""
        INSERT INTO text_content(file_id, body, extractor, created) VALUES(?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET body=excluded.body, extractor=excluded.extractor, created=excluded.created
        """, binds: [.text(fileID), .text(body), .text(extractor), .real(Date().timeIntervalSince1970)])
        try run("INSERT INTO text_fts(file_id, body) VALUES(?,?)", binds: [.text(fileID), .text(body)])
    }

    public func saveClassification(_ c: Classification, classifier: String) throws {
        let effectiveCategories = try categoryOverridesApplied(fileID: c.fileID, categories: c.categories)
        let effective = Classification(fileID: c.fileID, categories: effectiveCategories,
                                       description: c.description, confidence: c.confidence,
                                       reasonCodes: c.reasonCodes)
        try run("""
        INSERT INTO classifications(file_id, categories_json, description, confidence, reason_codes_json, classifier, created)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET
            categories_json=excluded.categories_json, description=excluded.description,
            confidence=excluded.confidence, reason_codes_json=excluded.reason_codes_json,
            classifier=excluded.classifier, created=excluded.created
        """, binds: [
            .text(effective.fileID),
            .text(String(data: try JSONEncoder().encode(effective.categories), encoding: .utf8)!),
            .text(effective.description), .real(effective.confidence),
            .text(String(data: try JSONEncoder().encode(effective.reasonCodes), encoding: .utf8)!),
            .text(classifier), .real(Date().timeIntervalSince1970),
        ])
        // Rebuild membership rows for this file.
        try run("DELETE FROM category_membership WHERE file_id=? AND source='classifier'", binds: [.text(effective.fileID)])
        for cat in effective.categories {
            let catID = try ensureCategory(named: cat)
            try run("INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
                    binds: [.int(catID), .text(effective.fileID)])
        }
        let now = Date().timeIntervalSince1970
        if ReviewState.from(confidence: effective.confidence) == .confident {
            try run("DELETE FROM review_inbox WHERE file_id=? AND state='open'", binds: [.text(effective.fileID)])
        } else {
            let reason = effective.reasonCodes.joined(separator: ",")
            try run("""
                INSERT INTO review_inbox(file_id, state, reason, created, updated)
                VALUES(?, 'open', ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET state='open', reason=excluded.reason, updated=excluded.updated
                """, binds: [.text(effective.fileID), .text(reason), .real(now), .real(now)])
        }
    }

    private func categoryOverridesApplied(fileID: String, categories: [String]) throws -> [String] {
        let rows = try query("SELECT category, action FROM category_overrides WHERE file_id=?",
                             binds: [.text(fileID)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        return Self.applyCategoryOverrides(categories: categories, rows: rows)
    }

    /// Transaction-local form used by the indexer before it rebuilds
    /// classifier memberships.
    public func txApplyCategoryOverrides(fileID: String, categories: [String]) throws -> [String] {
        let rows = try txQuery("SELECT category, action FROM category_overrides WHERE file_id=?",
                               binds: [.text(fileID)]) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        return Self.applyCategoryOverrides(categories: categories, rows: rows)
    }

    private static func applyCategoryOverrides(categories: [String],
                                               rows: [(String, String)]) -> [String] {
        var result = categories
        for (category, action) in rows {
            switch action {
            case ReviewCorrectionAction.addCategory.rawValue:
                if !result.contains(category) { result.append(category) }
            case ReviewCorrectionAction.removeCategory.rawValue:
                result.removeAll { $0 == category }
            default:
                continue
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Transaction-local category ensure — call only inside `transaction {}`.
    @discardableResult
    public func txEnsureCategory(named path: String) throws -> Int64 {
        var parent: Int64 = -1
        for component in path.split(separator: "/").map(String.init) {
            let rows = try txQuery(
                """
                SELECT c.id FROM virtual_categories c
                WHERE c.name=? AND (
                    (? < 0 AND c.parent_id IS NULL)
                 OR (? >= 0 AND c.parent_id = ?)
                ) LIMIT 1
                """, binds: [.text(component), .int(parent), .int(parent), .int(parent)]) { $0.int(0) }
            if let existing = rows.first, existing > 0 { parent = existing; continue }
            try txRun("INSERT INTO virtual_categories(name, parent_id) VALUES(?,?)",
                      binds: [.text(component), parent < 0 ? .null : .int(parent)])
            let newRows = try txQuery("SELECT last_insert_rowid()") { $0.int(0) }
            parent = newRows[0]
        }
        return parent
    }

    /// Ensure a (possibly nested "A/B/C") category exists; returns its id.
    @discardableResult
    public func ensureCategory(named path: String) throws -> Int64 {
        var parent: Int64 = -1
        for component in path.split(separator: "/").map(String.init) {
            let rows = try query(
                """
                SELECT c.id FROM virtual_categories c
                WHERE c.name=? AND (
                    (? < 0 AND c.parent_id IS NULL)
                 OR (? >= 0 AND c.parent_id = ?)
                ) LIMIT 1
                """, binds: [.text(component), .int(parent), .int(parent), .int(parent)]) { $0.int(0) }
            if let existing = rows.first, existing > 0 {
                parent = existing
                continue
            }
            try run("INSERT INTO virtual_categories(name, parent_id) VALUES(?,?)",
                    binds: [.text(component), parent < 0 ? .null : .int(parent)])
            let newRows = try query("SELECT last_insert_rowid()") { $0.int(0) }
            parent = newRows[0]
        }
        return parent
    }

    public func recordError(opaqueRef: String, stage: String, message: String) throws {
        try run("INSERT INTO errors(opaque_ref, stage, message, created) VALUES(?,?,?,?)",
                binds: [.text(opaqueRef), .text(stage), .text(message), .real(Date().timeIntervalSince1970)])
    }

    public func recordHash(fileID: String, size: Int64, sha256: Data) throws {
        try run("""
        INSERT INTO exact_hashes(file_id, size, sha256, computed) VALUES(?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET sha256=excluded.sha256, computed=excluded.computed
        """, binds: [.text(fileID), .int(size), .blob(sha256), .real(Date().timeIntervalSince1970)])
    }

    // MARK: - Vision / embeddings

    public func saveVisualFeatures(fileID: String, featurePrint: Data, revision: String) throws {
        try run("""
        INSERT INTO visual_features(file_id, featureprint, revision) VALUES(?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET featureprint=excluded.featureprint, revision=excluded.revision
        """, binds: [.text(fileID), .blob(featurePrint), .text(revision)])
    }

    public func visualFeatures(forFile id: String) throws -> (featurePrint: Data, revision: String)? {
        let rows = try query("SELECT featureprint, revision FROM visual_features WHERE file_id=?",
                             binds: [.text(id)]) { r in (r.blob(0) ?? Data(), r.text(1) ?? "") }
        return rows.first
    }

    public func saveEmbedding(fileID: String, model: String, dim: Int, vector: Data) throws {
        try run("""
        INSERT INTO embeddings(file_id, model, dim, vector) VALUES(?,?,?,?)
        ON CONFLICT(file_id, model) DO UPDATE SET dim=excluded.dim, vector=excluded.vector
        """, binds: [.text(fileID), .text(model), .int(Int64(dim)), .blob(vector)])
    }

    public func replaceEmbeddingChunks(fileID: String, model: String, chunks: [(dim: Int, vector: Data)]) throws {
        try run("DELETE FROM embedding_chunks WHERE file_id=? AND model=?", binds: [.text(fileID), .text(model)])
        for (idx, c) in chunks.enumerated() {
            try run("INSERT INTO embedding_chunks(file_id, model, chunk_index, dim, vector) VALUES(?,?,?,?,?)",
                    binds: [.text(fileID), .text(model), .int(Int64(idx)), .int(Int64(c.dim)), .blob(c.vector)])
        }
    }

    public func embedding(forFile id: String, model: String) throws -> (dim: Int, vector: Data)? {
        let rows = try query("SELECT dim, vector FROM embeddings WHERE file_id=? AND model=?",
                             binds: [.text(id), .text(model)]) { r in (Int(r.int(0)), r.blob(1) ?? Data()) }
        return rows.first
    }

    public func allVisualFeatures() throws -> [(fileID: String, featurePrint: Data)] {
        try query("SELECT file_id, featureprint FROM visual_features") { r in (r.text(0) ?? "", r.blob(1) ?? Data()) }
    }

    public func registerModelProvenance(model: String, version: String, source: String, license: String,
                                        expectedSHA256: String, actualSHA256: String? = nil, verified: Bool = false) throws {
        try run("""
        INSERT INTO model_provenance(model, version, source, license, expected_sha256, actual_sha256, verified, loaded_at)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(model) DO UPDATE SET version=excluded.version, source=excluded.source,
            license=excluded.license, expected_sha256=excluded.expected_sha256,
            actual_sha256=excluded.actual_sha256, verified=excluded.verified, loaded_at=excluded.loaded_at
        """, binds: [.text(model), .text(version), .text(source), .text(license),
                     .text(expectedSHA256), actualSHA256.map { .text($0) } ?? .null,
                     .int(verified ? 1 : 0), .real(Date().timeIntervalSince1970)])
    }

    /// Record a full embedding-space provenance snapshot (checkpoint SHAs, dims, pipeline rev).
    public func recordEmbeddingSpace(version: String, details: String) throws {
        try run("INSERT OR IGNORE INTO meta(k,v) VALUES('embedding_space_version', ?)", binds: [.text(version)])
        try run("UPDATE meta SET v=? WHERE k='embedding_space_version'", binds: [.text(version)])
        try run("INSERT OR IGNORE INTO meta(k,v) VALUES('embedding_space_details', ?)", binds: [.text(details)])
        try run("UPDATE meta SET v=? WHERE k='embedding_space_details'", binds: [.text(details)])
    }

    public func embeddingSpaceVersion() throws -> String? {
        let rows = try query("SELECT v FROM meta WHERE k='embedding_space_version'") { $0.text(0) }
        return rows.first ?? nil
    }

    // MARK: - Search

    public struct SearchHit: Sendable {
        public let fileID: String
        public let path: String
        public let snippet: String?
        public let rank: Double?
    }

    public struct FileSummary: Sendable, Equatable, Identifiable {
        public let id: String
        public let path: String
        public let kind: String
        public let status: String
        public let confidence: Double?

        public init(id: String, path: String, kind: String, status: String, confidence: Double?) {
            self.id = id
            self.path = path
            self.kind = kind
            self.status = status
            self.confidence = confidence
        }
    }

    /// FTS5 full-text search over extracted content (inside the encrypted db).
    public func searchExact(_ q: String, limit: Int = 50) throws -> [SearchHit] {
        // Escape double quotes so user input cannot break out of the FTS query syntax.
        let safe = q.replacingOccurrences(of: "\"", with: "\"\"")
        return try query("""
            SELECT f.id, f.path, snippet(text_fts, 1, '[', ']', '…', 12), bm25(text_fts)
            FROM text_fts JOIN files f ON f.id = text_fts.file_id
            WHERE text_fts MATCH ?
            ORDER BY bm25(text_fts)
            LIMIT ?
            """, binds: [.text("\"" + safe + "\""), .int(Int64(limit))]) { r in
            SearchHit(fileID: r.text(0) ?? "", path: r.text(1) ?? "",
                      snippet: r.text(2), rank: r.real(3))
        }
    }

    public func allFiles(statuses: [String]? = nil) throws -> [(id: String, path: String, size: Int64, mtime: Double, kind: String, status: String)] {
        let rows = try query("""
            SELECT id, path, size, mtime, kind, status FROM files
            """) { r in
            (id: r.text(0) ?? "", path: r.text(1) ?? "", size: r.int(2),
             mtime: r.real(3), kind: r.text(4) ?? "", status: r.text(5) ?? "")
        }
        guard let statuses else { return rows }
        let set = Set(statuses)
        return rows.filter { set.contains($0.status) }
    }

    public func fileSummaries(categoryPrefix: String? = nil, status: String? = nil,
                              limit: Int = 200) throws -> [FileSummary] {
        let rows = try query("""
            SELECT f.id, f.path, f.kind, f.status, c.confidence
            FROM files f LEFT JOIN classifications c ON c.file_id=f.id
            ORDER BY f.path
            """) { r in
            FileSummary(id: r.text(0) ?? "", path: r.text(1) ?? "", kind: r.text(2) ?? "",
                        status: r.text(3) ?? "", confidence: r.isNull(4) ? nil : r.real(4))
        }
        let categoryIDs: Set<String>? = try categoryPrefix.map { Set(try categoryFileIDs(prefix: $0)) }
        return Array(rows.filter { row in
            (status == nil || row.status == status) &&
            (categoryIDs == nil || categoryIDs!.contains(row.id))
        }.prefix(max(0, limit)))
    }

    public func categoryMemberships() throws -> [(categoryPath: String, fileID: String)] {
        try query("""
            WITH RECURSIVE category_paths(id, path) AS (
                SELECT id, name FROM virtual_categories WHERE parent_id IS NULL
                UNION ALL
                SELECT c.id, category_paths.path || '/' || c.name
                FROM virtual_categories c JOIN category_paths ON c.parent_id = category_paths.id
            )
            SELECT category_paths.path, m.file_id
            FROM category_membership m JOIN category_paths ON category_paths.id = m.category_id
            ORDER BY category_paths.path, m.file_id
            """) { r in (r.text(0) ?? "", r.text(1) ?? "") }
    }

    public func categoryFileIDs(prefix: String) throws -> Set<String> {
        let memberships = try categoryMemberships()
        return Set(memberships.compactMap { row in
            row.categoryPath == prefix || row.categoryPath.hasPrefix(prefix + "/") ? row.fileID : nil
        })
    }

    /// Exact duplicate candidates only. Near-duplicate and semantic families
    /// are separate similarity relations and must not appear in this view.
    public func duplicateFileIDs() throws -> Set<String> {
        let rows = try query("""
            SELECT h.file_id
            FROM exact_hashes h
            JOIN files f ON f.id=h.file_id
            JOIN (
                SELECT size, sha256 FROM exact_hashes
                GROUP BY size, sha256 HAVING count(*) > 1
            ) d ON d.size=h.size AND d.sha256=h.sha256
            WHERE f.status != 'missing'
            """) { $0.text(0) ?? "" }
        return Set(rows)
    }

    public func reviewItems(state: String = "open", limit: Int = 200) throws -> [ReviewItem] {
        let rows = try query("""
            SELECT r.file_id, f.path, COALESCE(c.confidence, 0),
                   COALESCE(c.categories_json, '[]'), COALESCE(c.reason_codes_json, '[]'),
                   r.state, r.updated
            FROM review_inbox r
            JOIN files f ON f.id = r.file_id
            LEFT JOIN classifications c ON c.file_id = r.file_id
            WHERE r.state=?
            ORDER BY r.updated DESC, r.file_id
            LIMIT ?
            """, binds: [.text(state), .int(Int64(max(1, limit)))]) { r in
            let categories = (try? JSONDecoder().decode([String].self, from: Data((r.text(3) ?? "[]").utf8))) ?? []
            let reasons = (try? JSONDecoder().decode([String].self, from: Data((r.text(4) ?? "[]").utf8))) ?? []
            return ReviewItem(fileID: r.text(0) ?? "", path: r.text(1) ?? "",
                              confidence: r.real(2), categories: categories,
                              reasonCodes: reasons, state: r.text(5) ?? state,
                              updated: r.real(6))
        }
        return rows
    }

    public func reviewSummary() throws -> ReviewSummary {
        let rows = try query("""
            SELECT state, count(*) FROM review_inbox GROUP BY state
            """) { ($0.text(0) ?? "", Int($0.int(1))) }
        return ReviewSummary(open: rows.first(where: { $0.0 == "open" })?.1 ?? 0,
                             resolved: rows.first(where: { $0.0 == "resolved" })?.1 ?? 0)
    }

    public func resolveReview(fileID: String) throws {
        try run("UPDATE review_inbox SET state='resolved', updated=? WHERE file_id=?",
                binds: [.real(Date().timeIntervalSince1970), .text(fileID)])
    }

    /// Apply a review correction only to catalog memberships and a persistent
    /// override. Re-indexing therefore cannot silently undo the user's choice.
    public func applyReviewCorrection(fileID: String, category: String,
                                      action: ReviewCorrectionAction,
                                      provenance: String = "review-ui") throws {
        let normalized = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        try transaction {
            let existenceRows = try txQuery("SELECT count(*) FROM files WHERE id=?", binds: [.text(fileID)]) { row in row.int(0) }
            let exists = existenceRows.first ?? 0
            guard exists > 0 else { return }
            try txRun("""
                INSERT INTO category_overrides(file_id, category, action, updated)
                VALUES(?,?,?,?)
                ON CONFLICT(file_id, category) DO UPDATE SET action=excluded.action, updated=excluded.updated
                """, binds: [.text(fileID), .text(normalized), .text(action.rawValue),
                               .real(Date().timeIntervalSince1970)])
            let categoryID = try txEnsureCategory(named: normalized)
            switch action {
            case .addCategory:
                try txRun("INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?, 'review')",
                         binds: [.int(categoryID), .text(fileID)])
            case .removeCategory:
                try txRun("DELETE FROM category_membership WHERE category_id=? AND file_id=?",
                         binds: [.int(categoryID), .text(fileID)])
            }
            try txRun("INSERT INTO review_corrections(file_id, category, action, provenance, created) VALUES(?,?,?,?,?)",
                     binds: [.text(fileID), .text(normalized), .text(action.rawValue), .text(provenance),
                             .real(Date().timeIntervalSince1970)])
            try txRun("UPDATE review_inbox SET state='resolved', updated=? WHERE file_id=?",
                     binds: [.real(Date().timeIntervalSince1970), .text(fileID)])
        }
    }

    public func refreshOrganizationGraph() throws -> OrganizationGraphSnapshot {
        let files = try allFiles()
        let memberships = try categoryMemberships()
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        let snapshot = OrganizationGraphBuilder().build(
            files: files.map { (id: $0.id, path: $0.path, status: $0.status, kind: $0.kind) },
            memberships: memberships,
            reviewFileIDs: reviewIDs,
            extraEdges: try organizationEdges()
        )
        try replaceOrganizationEdges(snapshot.edges)
        return snapshot
    }

    public func replaceOrganizationEdges(_ edges: [OrganizationGraphEdge]) throws {
        try transaction {
            try txRun("DELETE FROM organization_edges")
            for edge in edges {
                try txRun("INSERT INTO organization_edges(source_id, target_id, relation, weight) VALUES(?,?,?,?)",
                         binds: [.text(edge.sourceID), .text(edge.targetID), .text(edge.relation.rawValue), .real(edge.weight)])
            }
        }
    }

    public func organizationEdges() throws -> [OrganizationGraphEdge] {
        try query("SELECT source_id, target_id, relation, weight FROM organization_edges ORDER BY source_id, target_id, relation") { r in
            OrganizationGraphEdge(sourceID: r.text(0) ?? "", targetID: r.text(1) ?? "",
                                  relation: OrganizationRelation(rawValue: r.text(2) ?? "") ?? .category,
                                  weight: r.real(3))
        }
    }

    public func organizationGraph() throws -> OrganizationGraphSnapshot {
        let files = try allFiles()
        let memberships = try categoryMemberships()
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        return OrganizationGraphBuilder().build(
            files: files.map { (id: $0.id, path: $0.path, status: $0.status, kind: $0.kind) },
            memberships: memberships, reviewFileIDs: reviewIDs,
            extraEdges: try organizationEdges()
        )
    }

    public func coverage(roots: [String], excludedPaths: [String] = []) throws -> OnboardingCoverage {
        let rows = try allFiles()
        func normalized(_ path: String) -> String {
            guard path.count > 1, path.hasSuffix("/") else { return path }
            return String(path.dropLast())
        }
        let rootPrefixes = roots.map(normalized)
        let exclusions = excludedPaths.map(normalized)
        func under(_ path: String, _ prefix: String) -> Bool {
            path == prefix || path.hasPrefix(prefix + "/")
        }
        let scoped = rows.filter { row in rootPrefixes.contains { under(row.path, $0) } }
        let excluded = scoped.filter { row in exclusions.contains { under(row.path, $0) } }
        let eligible = scoped.filter { row in !exclusions.contains { under(row.path, $0) } }
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        return OnboardingCoverage(
            authorizedRoots: roots.count,
            excludedRoots: excludedPaths.count,
            catalogedFiles: eligible.count,
            indexedFiles: eligible.filter { $0.status == "indexed" }.count,
            reviewFiles: eligible.filter { reviewIDs.contains($0.id) }.count,
            missingFiles: eligible.filter { $0.status == "missing" }.count,
            excludedCatalogRows: excluded.count
        )
    }

    public func dashboard() throws -> CatalogDashboard {
        let counts = try counts()
        let summary = try reviewSummary()
        let categories = try query("SELECT count(*) FROM virtual_categories WHERE name != 'Review'") { Int($0.int(0)) }.first ?? 0
        let dupes = try query("""
            SELECT count(*) FROM (
                SELECT size, sha256 FROM exact_hashes GROUP BY size, sha256 HAVING count(*) > 1
            )
            """) { Int($0.int(0)) }.first ?? 0
        let edgeCount = try query("SELECT count(*) FROM organization_edges") { Int($0.int(0)) }.first ?? 0
        return CatalogDashboard(total: counts["total"] ?? 0, indexed: counts["indexed"] ?? 0,
                                review: summary.open, missing: counts["missing"] ?? 0,
                                categories: categories, duplicateGroups: dupes,
                                graphEdges: edgeCount)
    }

    public func fingerprint(forFile id: String) throws -> (size: Int64, mtime: Double)? {
        let rows = try query("SELECT size, mtime FROM files WHERE id=?", binds: [.text(id)]) { r in (r.int(0), r.real(1)) }
        return rows.first.map { ($0.0, $0.1) }
    }

    public func fileRow(id: String) throws -> (path: String, size: Int64)? {
        let rows = try query("SELECT path, size FROM files WHERE id=?", binds: [.text(id)]) { r in (r.text(0) ?? "", r.int(1)) }
        return rows.first
    }

    public func confidence(forFile id: String) throws -> Double? {
        let rows = try query("SELECT confidence FROM classifications WHERE file_id=?", binds: [.text(id)]) { $0.real(0) }
        return rows.first
    }

    public func fileKind(id: String) throws -> String? {
        let rows = try query("SELECT kind FROM files WHERE id=?", binds: [.text(id)]) { $0.text(0) }
        return rows.first ?? nil
    }

    public func counts() throws -> [String: Int] {
        var out: [String: Int] = [:]
        for status in ["pending", "indexed", "missing", "failed"] {
            let rows = try query("SELECT count(*) FROM files WHERE status=?", binds: [.text(status)]) { $0.int(0) }
            out[status] = Int(rows.first ?? 0)
        }
        let total = try query("SELECT count(*) FROM files") { $0.int(0) }
        out["total"] = Int(total.first ?? 0)
        return out
    }

    /// Verify the catalog is actually encrypted by checking the on-disk header.
    public static func onDiskHeaderIsPlaintextSQLite(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path),
              let hdr = try? fh.read(upToCount: 16), hdr.count >= 15 else { return false }
        fh.closeFile()
        return hdr.prefix(15) == Data("SQLite format 3".utf8)
    }
}
