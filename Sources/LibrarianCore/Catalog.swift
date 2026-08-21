import Foundation
import SQLCipher

/// SQLCipher-backed catalog: the ONLY writable store in the system.
/// Key lives in the macOS Keychain (see CatalogKeychain). All content —
/// filenames, OCR, transcripts, embeddings, classifications — is encrypted at
/// rest. FTS5 provides local full-text search inside the encrypted file.
public final class Catalog: @unchecked Sendable {

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "librarian.catalog.serial")
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
    }

    // MARK: - Low-level helpers

    public func run(_ sql: String, binds: [SQLValue] = []) throws {
        try queue.sync {
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
    }

    public func query<T>(_ sql: String, binds: [SQLValue] = [], _ row: (Row) throws -> T) throws -> [T] {
        return try queue.sync {
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
        try run("""
        INSERT INTO classifications(file_id, categories_json, description, confidence, reason_codes_json, classifier, created)
        VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET
            categories_json=excluded.categories_json, description=excluded.description,
            confidence=excluded.confidence, reason_codes_json=excluded.reason_codes_json,
            classifier=excluded.classifier, created=excluded.created
        """, binds: [
            .text(c.fileID),
            .text(String(data: try JSONEncoder().encode(c.categories), encoding: .utf8)!),
            .text(c.description), .real(c.confidence),
            .text(String(data: try JSONEncoder().encode(c.reasonCodes), encoding: .utf8)!),
            .text(classifier), .real(Date().timeIntervalSince1970),
        ])
        // Rebuild membership rows for this file.
        try run("DELETE FROM category_membership WHERE file_id=? AND source='classifier'", binds: [.text(c.fileID)])
        for cat in c.categories {
            let catID = try ensureCategory(named: cat)
            try run("INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
                    binds: [.int(catID), .text(c.fileID)])
        }
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

    // MARK: - Search

    public struct SearchHit: Sendable {
        public let fileID: String
        public let path: String
        public let snippet: String?
        public let rank: Double?
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
