import Foundation
import SQLCipher

/// SQLCipher-backed catalog: the ONLY writable store in the system.
/// Key lives in the app-owned macOS Keychain (see CatalogKeychain). All content —
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
    /// - Parameter key: raw key material from the app-owned Keychain.
    public init(path: String, key: Data) throws {
        queue.setSpecific(key: queueKey, value: ())
        self.path = path
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        var dbOut: OpaquePointer?
        guard sqlite3_open(path, &dbOut) == SQLITE_OK, let opened = dbOut else {
            let msg = dbOut.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let dbOut { sqlite3_close(dbOut) }
            throw CatalogError.openFailed(msg)
        }
        db = opened

        // Apply the key BEFORE any other statement.
        let rc = key.withUnsafeBytes { buf -> Int32 in
            guard let base = buf.baseAddress else { return SQLITE_ERROR }
            return sqlite3_key(opened, base, Int32(buf.count))
        }
        guard rc == SQLITE_OK else {
            sqlite3_close(opened)
            db = nil
            throw CatalogError.keyRejected
        }

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
            base_categories_json TEXT,
            description TEXT NOT NULL,
            confidence REAL NOT NULL,
            reason_codes_json TEXT NOT NULL,
            classifier TEXT NOT NULL,
            created REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS screenshot_assessments (
            file_id TEXT PRIMARY KEY REFERENCES files(id) ON DELETE CASCADE,
            is_screenshot INTEGER NOT NULL,
            subtype TEXT NOT NULL,
            confidence REAL NOT NULL,
            reason_codes_json TEXT NOT NULL,
            created REAL NOT NULL
        );

        -- NOTE: no UNIQUE(name) here. Same-named categories under different
        -- parents ("Archive" and "Tax/Archive") are valid taxonomy shapes;
        -- uniqueness is per-parent via the expression index created below.
        CREATE TABLE IF NOT EXISTS virtual_categories (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            parent_id INTEGER REFERENCES virtual_categories(id) ON DELETE CASCADE
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_virtual_categories_parent_name
            ON virtual_categories(COALESCE(parent_id, -1), name);

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

        -- Bounded project-level semantic rollups. These are aggregate catalog
        -- facts, not a second copy of per-file text or source bytes.
        CREATE TABLE IF NOT EXISTS project_summaries (
            root TEXT PRIMARY KEY,
            complete INTEGER NOT NULL,
            file_count INTEGER NOT NULL,
            indexed_file_count INTEGER NOT NULL,
            text_file_count INTEGER NOT NULL,
            embedding_file_count INTEGER NOT NULL,
            chunk_row_count INTEGER NOT NULL,
            vector_bytes INTEGER NOT NULL,
            kind_counts_json TEXT NOT NULL,
            summary TEXT NOT NULL,
            updated REAL NOT NULL
        );

        -- Similarity is derivative, encrypted catalog state. The relation and
        -- signal are explicit so near-duplicate review never masquerades as
        -- semantic relevance, and providers can be replaced without a schema
        -- rewrite.
        CREATE TABLE IF NOT EXISTS similarity_edges (
            a TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            b TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            score REAL NOT NULL,
            relation TEXT NOT NULL,
            signal TEXT NOT NULL,
            PRIMARY KEY (a, b, relation, signal)
        );
        CREATE INDEX IF NOT EXISTS idx_similarity_edges_relation ON similarity_edges(relation, score);
        CREATE TABLE IF NOT EXISTS similarity_clusters (
            id TEXT PRIMARY KEY,
            family_id TEXT NOT NULL,
            relation TEXT NOT NULL,
            representative TEXT NOT NULL,
            confidence REAL NOT NULL DEFAULT 0,
            reason TEXT NOT NULL DEFAULT '',
            updated REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS similarity_cluster_members (
            cluster_id TEXT NOT NULL REFERENCES similarity_clusters(id) ON DELETE CASCADE,
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            PRIMARY KEY (cluster_id, file_id)
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

        CREATE TABLE IF NOT EXISTS transcripts (
            file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
            start REAL NOT NULL,
            end REAL NOT NULL,
            text TEXT NOT NULL,
            provider TEXT NOT NULL,
            created REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_transcripts_file ON transcripts(file_id);
        -- Optional FTS for transcript search (plain table search also works)
        CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(
            file_id UNINDEXED, text, tokenize='unicode61'
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

        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            category TEXT NOT NULL,
            action TEXT NOT NULL,
            pattern_type TEXT,
            pattern TEXT,
            generation TEXT,
            created REAL NOT NULL,
            provenance TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_corrections_file ON corrections(file_id);
        CREATE TABLE IF NOT EXISTS learned_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            pattern_type TEXT NOT NULL,
            pattern TEXT NOT NULL,
            target_category TEXT NOT NULL,
            confidence REAL NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 0,
            provenance TEXT NOT NULL,
            created REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_learned_rules_unique ON learned_rules(pattern_type, pattern, target_category);
        CREATE TABLE IF NOT EXISTS learned_reindex_queue (
            file_id TEXT PRIMARY KEY,
            enqueued REAL NOT NULL
        );

        -- Journal of user-approved materializations (virtual group -> real
        -- folder moves). Catalog-only; rows exist so an apply can be undone.
        CREATE TABLE IF NOT EXISTS apply_journal (
            batch_id TEXT NOT NULL,
            applied_at REAL NOT NULL,
            file_id TEXT NOT NULL,
            from_path TEXT NOT NULL,
            to_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_apply_journal_batch ON apply_journal(batch_id, applied_at);

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
        // v2→v3: persist explainable cluster confidence/reason alongside the
        // existing virtual graph. Each ALTER is independently idempotent so a
        // crash between columns still converges on the next open.
        for (name, definition) in [("confidence", "REAL NOT NULL DEFAULT 0"),
                                   ("reason", "TEXT NOT NULL DEFAULT ''")] {
            let present = (try? query("SELECT 1 FROM pragma_table_info('similarity_clusters') WHERE name=?", binds: [.text(name)]) { _ in 1 }.first) != nil
            guard !present else { continue }
            do {
                try run("ALTER TABLE similarity_clusters ADD COLUMN \(name) \(definition)")
            } catch let e as CatalogError {
                if case .execFailed(let message) = e, message.contains("duplicate column") { /* already there */ } else { throw e }
            }
        }
        let currentVersion = try query("SELECT v FROM meta WHERE k='schema_version'") { $0.text(0) ?? "1" }
        if (currentVersion.first ?? "1") == "2" {
            try run("UPDATE meta SET v='3' WHERE k='schema_version'")
        }
        // v3→v4: retain the pre-learning classifier categories separately so
        // enabling/disabling a learned rule can rebuild memberships without
        // repeating OCR, Vision, embeddings, or source extraction.
        let hasBaseCategories = (try? query("SELECT 1 FROM pragma_table_info('classifications') WHERE name='base_categories_json'") { _ in 1 }.first) != nil
        if !hasBaseCategories {
            do {
                try run("ALTER TABLE classifications ADD COLUMN base_categories_json TEXT")
            } catch let e as CatalogError {
                if case .execFailed(let message) = e, message.contains("duplicate column") { /* already there */ } else { throw e }
            }
        }
        let latestVersion = try query("SELECT v FROM meta WHERE k='schema_version'") { $0.text(0) ?? "1" }
        if (latestVersion.first ?? "1") == "3" {
            try run("UPDATE meta SET v='4' WHERE k='schema_version'")
        }
        // v4→v5: aggregate project-level semantic rollups. The CREATE TABLE
        // above is idempotent so old catalogs converge even after a partial
        // migration.
        let summaryVersion = try query("SELECT v FROM meta WHERE k='schema_version'") { $0.text(0) ?? "1" }
        if (summaryVersion.first ?? "1") == "4" {
            try run("UPDATE meta SET v='5' WHERE k='schema_version'")
        }
        // v5→v6: rebuild virtual_categories without its historical table-level
        // UNIQUE(name). That constraint made a same-named child under two
        // different parents (e.g. "Archive" and "Tax/Archive") impossible:
        // txEnsureCategory's INSERT hit the constraint, the whole index commit
        // rolled back, and the file re-failed on every retry. Uniqueness is
        // now per-parent (COALESCE(parent_id,-1), name). Detection is the old
        // table SQL so the rebuild is idempotent and never touches catalogs
        // already created with the new schema.
        let categoryTableSQL = try query(
            "SELECT sql FROM sqlite_master WHERE type='table' AND name='virtual_categories'") {
            $0.text(0) ?? ""
        }.first ?? ""
        if categoryTableSQL.contains("NOT NULL UNIQUE") {
            let rebuilt = try transactionBodyWithoutForeignKeys {
                try rawExec("""
                    CREATE TABLE virtual_categories_rebuild (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        name TEXT NOT NULL,
                        parent_id INTEGER REFERENCES virtual_categories_rebuild(id) ON DELETE CASCADE
                    )
                    """)
                try rawExec("""
                    INSERT INTO virtual_categories_rebuild(id, name, parent_id)
                    SELECT id, name, parent_id FROM virtual_categories
                    """)
                try rawExec("DROP TABLE virtual_categories")
                try rawExec("ALTER TABLE virtual_categories_rebuild RENAME TO virtual_categories")
            }
            _ = rebuilt
            // The id is preserved by the copy, so memberships keep resolving.
            try run("CREATE UNIQUE INDEX IF NOT EXISTS idx_virtual_categories_parent_name ON virtual_categories(COALESCE(parent_id, -1), name)")
        }
        let taxonomyVersion = try query("SELECT v FROM meta WHERE k='schema_version'") { $0.text(0) ?? "1" }
        if (taxonomyVersion.first ?? "1") == "5" {
            try run("UPDATE meta SET v='6' WHERE k='schema_version'")
        }
    }

    /// Run a write sequence with foreign keys disabled for its duration.
    /// Needed by table rebuilds: dropping a table that others reference is
    /// only legal with FK enforcement off, and the pragma is a no-op inside
    /// a transaction, so it is toggled around the caller's transaction.
    private func transactionBodyWithoutForeignKeys(_ body: () throws -> Void) throws -> Bool {
        try rawExec("PRAGMA foreign_keys=OFF")
        do {
            try transaction {
                try body()
            }
            try rawExec("PRAGMA foreign_keys=ON")
            return true
        } catch {
            try? rawExec("PRAGMA foreign_keys=ON")
            throw error
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
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_ROW {
                out.append(try row(Row(stmt: stmt!)))
            } else if rc == SQLITE_DONE {
                return out
            } else {
                throw CatalogError.execFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    /// Run a block of catalog writes atomically: all of it lands, or none.
    /// Used by the indexer so a file's text/classification/hash are committed
    /// together, only AFTER the final identity recheck passes.
    /// IMPORTANT: body must use rawRun/rawQuery/execSQL helpers that do NOT
    /// re-enter queue.sync — this method already holds the serial queue.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        var result: Result<T, Error>?
        queue.sync {
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

    /// Mark a deleted file or directory subtree missing entirely in SQL. The
    /// live coordinator uses this instead of loading every catalog row into a
    /// Swift array during a directory deletion event.
    public func markMissing(atOrUnder root: String) throws {
        let normalized = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        if normalized == "/" {
            try run("UPDATE files SET status='missing' WHERE status!='missing' AND status!='unscoped' AND path LIKE '/%' ESCAPE '~'")
            return
        }
        let childPattern = Self.escapeLikePattern(normalized) + "/%"
        try run("""
            UPDATE files SET status='missing'
            WHERE status!='missing' AND status!='unscoped'
              AND (path=? OR path LIKE ? ESCAPE '~')
            """, binds: [.text(normalized), .text(childPattern)])
    }

    /// Remove a source root from the visible catalog scope without touching
    /// any original. Re-adding the same root makes its rows eligible again;
    /// the next index pass refreshes their derived state.
    public func markRootUnscoped(root: String) throws {
        let normalized = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        if normalized == "/" {
            try run("UPDATE files SET status='unscoped' WHERE path LIKE '/%' ESCAPE '~'")
            try run("DELETE FROM project_summaries WHERE root LIKE '/%' ESCAPE '~'")
            try? clearAccessBackoff(atOrUnder: normalized)
            return
        }
        let childPattern = Self.escapeLikePattern(normalized) + "/%"
        try run("""
            UPDATE files SET status='unscoped'
            WHERE path=? OR path LIKE ?
            ESCAPE '~'
            """, binds: [.text(normalized), .text(childPattern)])
        // Nested roots inside the unscoped root lose their scope too, so
        // their persisted summaries must not outlive the data they describe.
        try run("""
            DELETE FROM project_summaries WHERE root=? OR root LIKE ?
            ESCAPE '~'
            """, binds: [.text(normalized), .text(childPattern)])
        try? clearAccessBackoff(atOrUnder: normalized)
    }

    public func restoreRootScope(root: String) throws {
        let normalized = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        if normalized == "/" {
            try run("UPDATE files SET status='pending' WHERE status='unscoped' AND path LIKE '/%' ESCAPE '~'")
            try? clearAccessBackoff(atOrUnder: normalized)
            return
        }
        let childPattern = Self.escapeLikePattern(normalized) + "/%"
        try run("""
            UPDATE files SET status='pending'
            WHERE status='unscoped' AND (path=? OR path LIKE ? ESCAPE '~')
            """, binds: [.text(normalized), .text(childPattern)])
        // Reauthorization is an explicit retry. Do not let stale automatic
        // backoff keep the newly restored root silently skipped.
        try? clearAccessBackoff(atOrUnder: normalized)
    }

    private static func escapeLikePattern(_ value: String) -> String {
        value
            .replacingOccurrences(of: "~", with: "~~")
            .replacingOccurrences(of: "%", with: "~%")
            .replacingOccurrences(of: "_", with: "~_")
    }

    /// Run a multi-statement write sequence atomically when called from
    /// outside the catalog queue. When already inside a transaction on the
    /// queue (the indexer's commit path), statements join that transaction
    /// instead of attempting a nested BEGIN.
    private func atomically(_ body: () throws -> Void) throws {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            try body()
        } else {
            try transaction { try body() }
        }
    }

    public func saveText(fileID: String, body: String, extractor: String) throws {
        try atomically {
            try run("DELETE FROM text_fts WHERE file_id=?", binds: [.text(fileID)])
            try run("""
            INSERT INTO text_content(file_id, body, extractor, created) VALUES(?,?,?,?)
            ON CONFLICT(file_id) DO UPDATE SET body=excluded.body, extractor=excluded.extractor, created=excluded.created
            """, binds: [.text(fileID), .text(body), .text(extractor), .real(Date().timeIntervalSince1970)])
            try run("INSERT INTO text_fts(file_id, body) VALUES(?,?)", binds: [.text(fileID), .text(body)])
        }
    }

    public func saveClassification(_ c: Classification, classifier: String) throws {
        let effectiveCategories = try categoryOverridesApplied(fileID: c.fileID, categories: c.categories)
        let effective = Classification(fileID: c.fileID, categories: effectiveCategories,
                                       description: c.description, confidence: c.confidence,
                                       reasonCodes: c.reasonCodes)
        try run("""
        INSERT INTO classifications(file_id, categories_json, base_categories_json, description, confidence, reason_codes_json, classifier, created)
        VALUES(?,?,?,?,?,?,?,?)
        ON CONFLICT(file_id) DO UPDATE SET
            categories_json=excluded.categories_json, description=excluded.description,
            base_categories_json=excluded.base_categories_json,
            confidence=excluded.confidence, reason_codes_json=excluded.reason_codes_json,
            classifier=excluded.classifier, created=excluded.created
        """, binds: [
            .text(effective.fileID),
            .text(String(data: try JSONEncoder().encode(effective.categories), encoding: .utf8)!),
            .text(String(data: try JSONEncoder().encode(c.categories), encoding: .utf8)!),
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
        if ReviewState.from(confidence: effective.confidence) == .confident
            || effective.categories.contains("Review/Unknown") {
            try run("DELETE FROM review_inbox WHERE file_id=? AND state='open'", binds: [.text(effective.fileID)])
        } else {
            let reason = effective.reasonCodes.joined(separator: ",")
            try run("""
                INSERT INTO review_inbox(file_id, state, reason, created, updated)
                VALUES(?, 'open', ?, ?, ?)
                ON CONFLICT(file_id) DO UPDATE SET state='open', reason=excluded.reason, updated=excluded.updated
                WHERE state != 'resolved'
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
        // `markUnknown` is a deliberate terminal classification decision for
        // the current correction state. Do not let a later classifier pass
        // resurrect stale or newly inferred categories beside it.
        if rows.contains(where: {
            $0.0 == "Review/Unknown" && $0.1 == ReviewCorrectionAction.addCategory.rawValue
        }) {
            return ["Review/Unknown"]
        }
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

    /// Persisted separately so screenshot-specific fields remain queryable
    /// without parsing the general classifier output. This table is inside the
    /// same SQLCipher database and is written in the index transaction.
    public func saveScreenshotAssessment(fileID: String, assessment: ScreenshotAssessment) throws {
        try transaction { try txSaveScreenshotAssessment(fileID: fileID, assessment: assessment) }
    }

    public func txSaveScreenshotAssessment(fileID: String, assessment: ScreenshotAssessment) throws {
        let reasons = String(data: try JSONEncoder().encode(assessment.reasonCodes), encoding: .utf8)!
        try txRun("""
            INSERT INTO screenshot_assessments(file_id, is_screenshot, subtype, confidence, reason_codes_json, created)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(file_id) DO UPDATE SET is_screenshot=excluded.is_screenshot,
                subtype=excluded.subtype, confidence=excluded.confidence,
                reason_codes_json=excluded.reason_codes_json, created=excluded.created
            """, binds: [.text(fileID), .int(assessment.isScreenshot ? 1 : 0),
                          .text(assessment.subtype.rawValue), .real(Double(assessment.confidence)),
                          .text(reasons), .real(Date().timeIntervalSince1970)])
    }

    public func screenshotAssessment(forFile id: String) throws -> ScreenshotAssessment? {
        let rows = try query("SELECT is_screenshot, subtype, confidence, reason_codes_json FROM screenshot_assessments WHERE file_id=?",
                             binds: [.text(id)]) { row -> ScreenshotAssessment? in
            guard let subtype = ScreenshotSubtype(rawValue: row.text(1) ?? "unknown"),
                  let data = row.text(3)?.data(using: .utf8),
                  let reasons = try? JSONDecoder().decode([String].self, from: data) else { return nil }
            return ScreenshotAssessment(isScreenshot: row.int(0) != 0, subtype: subtype,
                                        confidence: Float(row.real(2)), reasonCodes: reasons)
        }
        return rows.first ?? nil
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
        ON CONFLICT(file_id) DO UPDATE SET size=excluded.size, sha256=excluded.sha256, computed=excluded.computed
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
        try atomically {
            try run("DELETE FROM embedding_chunks WHERE file_id=? AND model=?", binds: [.text(fileID), .text(model)])
            for (idx, c) in chunks.enumerated() {
                try run("INSERT INTO embedding_chunks(file_id, model, chunk_index, dim, vector) VALUES(?,?,?,?,?)",
                        binds: [.text(fileID), .text(model), .int(Int64(idx)), .int(Int64(c.dim)), .blob(c.vector)])
            }
        }
    }

    public func embedding(forFile id: String, model: String) throws -> (dim: Int, vector: Data)? {
        let rows = try query("SELECT dim, vector FROM embeddings WHERE file_id=? AND model=?",
                             binds: [.text(id), .text(model)]) { r in (Int(r.int(0)), r.blob(1) ?? Data()) }
        return rows.first
    }

    public func allVisualFeatures() throws -> [(fileID: String, featurePrint: Data)] {
        try query("""
            SELECT v.file_id, v.featureprint
            FROM visual_features v JOIN files f ON f.id=v.file_id
            WHERE f.status='indexed'
            """) { r in (r.text(0) ?? "", r.blob(1) ?? Data()) }
    }

    // MARK: - Similarity graph (stored inside SQLCipher)

    /// Atomically replace the persisted derivative graph. The caller owns
    /// thresholds/adapters; Catalog only stores the already-vetted result.
    public func replaceSimilarityGraph(_ update: SimilarityGraphUpdate) throws {
        try transaction {
            try txRun("DELETE FROM similarity_cluster_members")
            try txRun("DELETE FROM similarity_clusters")
            try txRun("DELETE FROM similarity_edges")
            for edge in update.edges {
                try txRun("INSERT INTO similarity_edges(a,b,score,relation,signal) VALUES(?,?,?,?,?)", binds: [
                    .text(edge.a), .text(edge.b), .real(Double(edge.score)), .text(edge.relation.rawValue), .text(edge.signal.rawValue)
                ])
            }
            for cluster in update.clusters {
                try txRun("INSERT INTO similarity_clusters(id,family_id,relation,representative,confidence,reason,updated) VALUES(?,?,?,?,?,?,?)", binds: [
                    .text(cluster.id), .text(cluster.familyID), .text(cluster.relation.rawValue), .text(cluster.representative),
                    .real(Double(cluster.confidence)), .text(cluster.reason), .real(Date().timeIntervalSince1970)
                ])
                for member in cluster.members {
                    try txRun("INSERT INTO similarity_cluster_members(cluster_id,file_id) VALUES(?,?)", binds: [.text(cluster.id), .text(member)])
                }
            }
        }
    }

    public func similarityEdges(relation: SimilarityRelation? = nil) throws -> [SimilarityEdge] {
        let sql = "SELECT a,b,score,relation,signal FROM similarity_edges" + (relation == nil ? "" : " WHERE relation=?") + " ORDER BY a,b,relation,signal"
        let binds = relation.map { [SQLValue.text($0.rawValue)] } ?? []
        return try query(sql, binds: binds) { r in
            SimilarityEdge(a: r.text(0) ?? "", b: r.text(1) ?? "", score: Float(r.real(2)),
                           relation: SimilarityRelation(rawValue: r.text(3) ?? "") ?? .nearDuplicate,
                           signal: SimilaritySignal(rawValue: r.text(4) ?? "") ?? .featurePrint)
        }
    }

    public func similarityClusters(relation: SimilarityRelation? = nil) throws -> [SimilarityCluster] {
        let sql = "SELECT id,family_id,relation,representative,confidence,reason FROM similarity_clusters" + (relation == nil ? "" : " WHERE relation=?") + " ORDER BY id"
        let binds = relation.map { [SQLValue.text($0.rawValue)] } ?? []
        let rows = try query(sql, binds: binds) { r in
            (r.text(0) ?? "", r.text(1) ?? "", SimilarityRelation(rawValue: r.text(2) ?? "") ?? .nearDuplicate,
             r.text(3) ?? "", Float(r.real(4)), r.text(5) ?? "")
        }
        let members = try query("""
            SELECT cluster_id, file_id
            FROM similarity_cluster_members
            ORDER BY cluster_id, file_id
            """) { ($0.text(0) ?? "", $0.text(1) ?? "") }
        var membersByCluster: [String: [String]] = [:]
        for (clusterID, fileID) in members {
            membersByCluster[clusterID, default: []].append(fileID)
        }
        return rows.map { row in
            SimilarityCluster(id: row.0, members: membersByCluster[row.0] ?? [],
                              representative: row.3, relation: row.2,
                              familyID: row.1, confidence: row.4,
                              reason: row.5.isEmpty ? nil : row.5)
        }
    }

    /// Build provider-neutral similarity nodes from the active catalog rows.
    /// Missing files are excluded; callers can pass their IDs separately to
    /// the incremental graph updater so their old edges are removed.
    public func similarityNodes() throws -> [SimilarityNode] {
        let files = try allFiles(statuses: ["indexed"])
        let activeIDs = Set(files.map(\.id))
        var hashes: [String: Data] = [:]
        let hashRows: [(String?, Data?)] = try query(
            """
            SELECT h.file_id, h.sha256
            FROM exact_hashes h JOIN files f ON f.id=h.file_id
            WHERE f.status='indexed'
            """) { r in (r.text(0), r.blob(1)) }
        for (id, hash) in hashRows {
            if let id, let hash { hashes[id] = hash }
        }
        var features: [String: Data] = [:]
        let featureRows: [(String?, Data?)] = try query(
            """
            SELECT v.file_id, v.featureprint
            FROM visual_features v JOIN files f ON f.id=v.file_id
            WHERE f.status='indexed'
            """) { r in (r.text(0), r.blob(1)) }
        for (id, feature) in featureRows {
            if let id, let feature { features[id] = feature }
        }
        var embeddings: [String: [String: Data]] = [:]
        let embeddingRows: [(String?, String?, Data?)] = try query(
            """
            SELECT e.file_id, e.model, e.vector
            FROM embeddings e JOIN files f ON f.id=e.file_id
            WHERE f.status='indexed'
            """) { r in (r.text(0), r.text(1), r.blob(2)) }
        for (id, model, vector) in embeddingRows {
            guard let id, let model, let vector else { continue }
            embeddings[id, default: [:]][model] = vector
        }
        var confidence: [String: Float] = [:]
        let confidenceRows: [(String?, Double)] = try query(
            """
            SELECT c.file_id, c.confidence
            FROM classifications c JOIN files f ON f.id=c.file_id
            WHERE f.status='indexed'
            """) { r in (r.text(0), r.real(1)) }
        for (id, value) in confidenceRows {
            if let id { confidence[id] = Float(value) }
        }
        return files.map { file in
            SimilarityNode(id: file.id,
                           exactHash: hashes[file.id],
                           featurePrint: features[file.id],
                           embeddings: embeddings[file.id] ?? [:],
                           confidence: confidence[file.id] ?? 0)
        }.filter { activeIDs.contains($0.id) }
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

    /// Build an injection-safe FTS5 MATCH query. Every token becomes a quoted
    /// term joined by implicit AND, so multi-word queries match documents that
    /// contain the words anywhere instead of requiring the exact phrase.
    /// Double quotes inside the input delimit phrases and are otherwise
    /// stripped from terms so a crafted string can never escape the quoting.
    public static func ftsMatchQuery(_ input: String) -> String {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        func flush() {
            if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        for character in input {
            if character == "\"" {
                if inQuotes {
                    flush()
                    inQuotes = false
                } else {
                    flush()
                    inQuotes = true
                }
            } else if character.isWhitespace, !inQuotes {
                flush()
            } else {
                current.append(character)
            }
        }
        flush()
        return tokens
            .map { "\"" + $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "") + "\"" }
            .joined(separator: " ")
    }

    /// FTS5 full-text search over extracted content (inside the encrypted db).
    public func searchExact(_ q: String, limit: Int = 50) throws -> [SearchHit] {
        guard limit > 0,
              !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let match = Self.ftsMatchQuery(q)
        guard !match.isEmpty else { return [] }
        let textHits = try query("""
            SELECT f.id, f.path, snippet(text_fts, 1, '[', ']', '…', 12), bm25(text_fts)
            FROM text_fts JOIN files f ON f.id = text_fts.file_id
            WHERE f.status = 'indexed' AND text_fts MATCH ?
            ORDER BY bm25(text_fts)
            LIMIT ?
            """, binds: [.text(match), .int(Int64(limit))]) { r in
            SearchHit(fileID: r.text(0) ?? "", path: r.text(1) ?? "",
                      snippet: r.text(2), rank: r.real(3))
        }
        let transcriptHits = try query("""
            SELECT f.id, f.path, snippet(transcripts_fts, 1, '[', ']', '…', 12), bm25(transcripts_fts)
            FROM transcripts_fts JOIN files f ON f.id = transcripts_fts.file_id
            WHERE f.status = 'indexed' AND transcripts_fts MATCH ?
            ORDER BY bm25(transcripts_fts)
            LIMIT ?
            """, binds: [.text(match), .int(Int64(limit))]) { r in
            SearchHit(fileID: r.text(0) ?? "", path: r.text(1) ?? "",
                      snippet: r.text(2), rank: r.real(3))
        }
        var merged: [SearchHit] = []
        var seen = Set<String>()
        for hit in textHits + transcriptHits where seen.insert(hit.fileID).inserted {
            merged.append(hit)
            if merged.count == limit { break }
        }
        return merged
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
            WHERE f.status != 'unscoped'
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

    // MARK: - Apply journal (user-approved materialization of virtual groups)

    public struct ApplyJournalEntry: Sendable, Equatable {
        public let fileID: String
        public let fromPath: String
        public let toPath: String

        public init(fileID: String, fromPath: String, toPath: String) {
            self.fileID = fileID
            self.fromPath = fromPath
            self.toPath = toPath
        }
    }

    /// Record every successful move of a user-approved apply batch. Callers
    /// must only journal moves that actually happened so undo stays truthful.
    public func recordApplyBatch(batchID: String, appliedAt: TimeInterval, entries: [ApplyJournalEntry]) throws {
        guard !batchID.isEmpty, !entries.isEmpty else { return }
        try transaction {
            for entry in entries {
                try run("""
                    INSERT INTO apply_journal(batch_id, applied_at, file_id, from_path, to_path)
                    VALUES (?, ?, ?, ?, ?)
                    """, binds: [.text(batchID), .real(appliedAt), .text(entry.fileID),
                                 .text(entry.fromPath), .text(entry.toPath)])
            }
        }
    }

    public func latestApplyBatchID() throws -> String? {
        try query("""
            SELECT batch_id FROM apply_journal
            ORDER BY applied_at DESC, rowid DESC LIMIT 1
            """) { $0.text(0) ?? "" }.first
    }

    public func applyBatchEntries(batchID: String) throws -> [ApplyJournalEntry] {
        try query("""
            SELECT file_id, from_path, to_path FROM apply_journal
            WHERE batch_id = ? ORDER BY rowid
            """, binds: [.text(batchID)]) { row in
            ApplyJournalEntry(fileID: row.text(0) ?? "",
                              fromPath: row.text(1) ?? "",
                              toPath: row.text(2) ?? "")
        }
    }

    /// Remove one batch's journal rows after a complete, verified undo.
    public func deleteApplyBatch(batchID: String) throws {
        try run("DELETE FROM apply_journal WHERE batch_id = ?", binds: [.text(batchID)])
    }

    /// Keep the catalog coherent after a real move: the file keeps its row and
    /// memberships; only its recorded source path changes. The update is
    /// guarded by the original path so a stale plan can never rewrite a row
    /// that no longer matches what was moved.
    @discardableResult
    public func updateAppliedPath(fileID: String, fromPath: String, toPath: String) throws -> Bool {
        let update = {
            try self.rawRun("""
                UPDATE files SET path = ? WHERE id = ? AND path = ?
                """, binds: [.text(toPath), .text(fileID), .text(fromPath)])
            return sqlite3_changes(self.db) == 1
        }
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try update()
        }
        return try queue.sync { try update() }
    }

    /// Exact duplicate candidates only. Near-duplicate and semantic families
    /// are separate similarity relations and must not appear in this view.
    public func duplicateFileIDs() throws -> Set<String> {
        let rows = try query("""
            SELECT h.file_id
            FROM exact_hashes h
            JOIN files f ON f.id=h.file_id
            JOIN (
                -- Groups form over indexed files only, matching the
                -- dashboard: a deleted/unscoped twin must not make its
                -- surviving copy look like a duplicate.
                SELECT dhe.size, dhe.sha256 FROM exact_hashes dhe
                JOIN files ef ON ef.id=dhe.file_id
                WHERE ef.status='indexed'
                GROUP BY dhe.size, dhe.sha256 HAVING count(*) > 1
            ) d ON d.size=h.size AND d.sha256=h.sha256
            WHERE f.status='indexed'
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
            WHERE r.state=? AND f.status != 'unscoped'
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
            SELECT r.state, count(*)
            FROM review_inbox r JOIN files f ON f.id=r.file_id
            WHERE f.status != 'unscoped'
            GROUP BY r.state
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
        let correctionCategory = action == .markUnknown ? "Review/Unknown" : normalized
        guard action == .markUnknown || !normalized.isEmpty else { return }
        try ensureLearnedTables()
        var learningPattern: (patternType: LearnedPatternType, pattern: String)?
        try transaction {
            let existenceRows = try txQuery("SELECT count(*) FROM files WHERE id=?", binds: [.text(fileID)]) { row in row.int(0) }
            let exists = existenceRows.first ?? 0
            guard exists > 0 else { return }
            if action == .markUnknown {
                // This correction supersedes both classifier memberships and
                // earlier manual category additions. The explicit override
                // below keeps the decision stable across re-indexing.
                try txRun("DELETE FROM category_membership WHERE file_id=?",
                         binds: [.text(fileID)])
                let unknownID = try txEnsureCategory(named: correctionCategory)
                try txRun(
                    "INSERT INTO category_membership(category_id, file_id, source) VALUES(?,?, 'review')",
                    binds: [.int(unknownID), .text(fileID)])
                try txRun("""
                    INSERT INTO category_overrides(file_id, category, action, updated)
                    VALUES(?,?,?,?)
                    ON CONFLICT(file_id, category) DO UPDATE SET action=excluded.action, updated=excluded.updated
                    """, binds: [.text(fileID), .text(correctionCategory),
                                   .text(ReviewCorrectionAction.addCategory.rawValue),
                                   .real(Date().timeIntervalSince1970)])
            } else {
                // An explicit category correction supersedes the terminal
                // unknown decision. Without clearing this override,
                // txApplyCategoryOverrides would keep collapsing every later
                // classifier refresh back to Review/Unknown.
                try txRun(
                    "DELETE FROM category_overrides WHERE file_id=? AND category=? AND action=?",
                    binds: [.text(fileID), .text("Review/Unknown"),
                            .text(ReviewCorrectionAction.addCategory.rawValue)])
                // An explicit correction also supersedes the 'Review/Unknown'
                // membership row markUnknown inserted (source='review' rows
                // survive classifier rebuilds, so it must be removed here).
                // The category is hierarchical (Review → Unknown), so match
                // by full path, not by component name.
                try txRun("""
                    DELETE FROM category_membership WHERE file_id=? AND category_id IN (
                        WITH RECURSIVE category_paths(id, path) AS (
                            SELECT id, name FROM virtual_categories WHERE parent_id IS NULL
                            UNION ALL
                            SELECT c.id, category_paths.path || '/' || c.name
                            FROM virtual_categories c JOIN category_paths ON c.parent_id = category_paths.id
                        )
                        SELECT id FROM category_paths WHERE path='Review/Unknown'
                    )
                    """, binds: [.text(fileID)])
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
                case .markUnknown:
                    break
                }
            }
            try txRun("INSERT INTO review_corrections(file_id, category, action, provenance, created) VALUES(?,?,?,?,?)",
                     binds: [.text(fileID), .text(correctionCategory), .text(action.rawValue), .text(provenance),
                             .real(Date().timeIntervalSince1970)])
            try txRun("UPDATE review_inbox SET state='resolved', updated=? WHERE file_id=?",
                     binds: [.real(Date().timeIntervalSince1970), .text(fileID)])
            learningPattern = try txRecordReviewCorrection(
                fileID: fileID, category: correctionCategory, action: action, provenance: provenance)
        }
        if action != .markUnknown, let learningPattern {
            // Promotion is deliberately outside the correction transaction:
            // the rule is a derived, disabled-by-default artifact. A negative
            // correction can only block/reduce an existing rule.
            _ = try? promoteIfNeeded(patternType: learningPattern.patternType,
                                     pattern: learningPattern.pattern,
                                     targetCategory: normalized,
                                     provenance: provenance)
        }
    }

    public func refreshOrganizationGraph() throws -> OrganizationGraphSnapshot {
        let files = try allFiles().filter { $0.status != "unscoped" }
        let memberships = try categoryMemberships()
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        let snapshot = OrganizationGraphBuilder().build(
            files: files.map { (id: $0.id, path: $0.path, status: $0.status, kind: $0.kind) },
            memberships: memberships,
            reviewFileIDs: reviewIDs,
            similarityClusters: try similarityClusters(),
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
        let files = try allFiles().filter { $0.status != "unscoped" }
        let memberships = try categoryMemberships()
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        return OrganizationGraphBuilder().build(
            files: files.map { (id: $0.id, path: $0.path, status: $0.status, kind: $0.kind) },
            memberships: memberships, reviewFileIDs: reviewIDs,
            similarityClusters: try similarityClusters(),
            extraEdges: try organizationEdges()
        )
    }

    public func coverage(
        roots: [String],
        excludedPaths: [String] = [],
        excludedDirectoryNames: Set<String> = OnboardingExclusions.defaultDirectoryNames
    ) throws -> OnboardingCoverage {
        let rows = try allFiles()
        func normalized(_ path: String) -> String {
            guard path.count > 1, path.hasSuffix("/") else { return path }
            return String(path.dropLast())
        }
        let rootPrefixes = roots.map(normalized)
        let exclusions = excludedPaths.map(normalized).sorted()
        func hasExcludedDirectory(_ path: String) -> Bool {
            path.split(separator: "/").contains { excludedDirectoryNames.contains(String($0)) }
        }
        func under(_ path: String, _ prefix: String) -> Bool {
            if prefix == "/" { return path.hasPrefix("/") }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
        let scoped = rows.filter { row in
            row.status != "unscoped" && rootPrefixes.contains { under(row.path, $0) }
        }
        let excluded = scoped.filter { row in
            exclusions.contains { under(row.path, $0) } || hasExcludedDirectory(row.path)
        }
        let eligible = scoped.filter { row in
            !exclusions.contains { under(row.path, $0) } && !hasExcludedDirectory(row.path)
        }
        let reviewIDs = Set(try reviewItems(limit: Int.max).map(\.fileID))
        let rootCoverage = rootPrefixes.map { root in
            let rootRows = scoped.filter { row in under(row.path, root) }
            let skippedRows = rootRows.filter { row in
                exclusions.contains { prefix in under(row.path, prefix) }
                    || hasExcludedDirectory(row.path)
            }
            var reasons: [String: Int] = [:]
            for row in skippedRows {
                let reason: String
                if let prefix = exclusions.first(where: { under(row.path, $0) }) {
                    reason = "excluded-prefix:\((prefix as NSString).lastPathComponent)"
                } else if let name = row.path.split(separator: "/")
                    .map(String.init)
                    .first(where: excludedDirectoryNames.contains) {
                    reason = "excluded-directory:\(name)"
                } else {
                    reason = "excluded"
                }
                reasons[reason, default: 0] += 1
            }
            return OnboardingRootCoverage(
                root: root,
                eligibleFiles: rootRows.count - skippedRows.count,
                indexedFiles: rootRows.filter { row in
                    !exclusions.contains { prefix in under(row.path, prefix) }
                        && !hasExcludedDirectory(row.path)
                        && row.status == "indexed"
                }.count,
                reviewFiles: rootRows.filter { row in
                    !exclusions.contains { prefix in under(row.path, prefix) }
                        && !hasExcludedDirectory(row.path)
                        && reviewIDs.contains(row.id)
                }.count,
                missingFiles: rootRows.filter { row in
                    !exclusions.contains { prefix in under(row.path, prefix) }
                        && !hasExcludedDirectory(row.path)
                        && row.status == "missing"
                }.count,
                skippedFiles: skippedRows.count,
                exclusionReasons: reasons)
        }
        return OnboardingCoverage(
            authorizedRoots: roots.count,
            excludedRoots: excludedPaths.count,
            catalogedFiles: eligible.count,
            indexedFiles: eligible.filter { $0.status == "indexed" }.count,
            reviewFiles: eligible.filter { reviewIDs.contains($0.id) }.count,
            missingFiles: eligible.filter { $0.status == "missing" }.count,
            excludedCatalogRows: excluded.count,
            roots: rootCoverage
        )
    }

    public func dashboard() throws -> CatalogDashboard {
        let counts = try counts()
        let summary = try reviewSummary()
        let categories = try query("SELECT count(*) FROM virtual_categories WHERE name != 'Review'") { Int($0.int(0)) }.first ?? 0
        let dupes = try query("""
            SELECT count(*) FROM (
                SELECT h.size, h.sha256
                FROM exact_hashes h JOIN files f ON f.id=h.file_id
                WHERE f.status='indexed'
                GROUP BY h.size, h.sha256 HAVING count(*) > 1
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

    public func fileID(forPath path: String) throws -> String? {
        let rows = try query("SELECT id FROM files WHERE path=?", binds: [.text(path)]) { $0.text(0) }
        return rows.first ?? nil
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
        let total = try query("SELECT count(*) FROM files WHERE status != 'unscoped'") { $0.int(0) }
        out["total"] = Int(total.first ?? 0)
        let embeddingRows = try query("SELECT count(*), COALESCE(sum(length(vector)), 0) FROM embeddings") {
            (Int($0.int(0)), Int($0.int(1)))
        }
        out["embedding_rows"] = embeddingRows.first?.0 ?? 0
        out["embedding_bytes"] = embeddingRows.first?.1 ?? 0
        let chunkRows = try query("SELECT count(*), COALESCE(sum(length(vector)), 0) FROM embedding_chunks") {
            (Int($0.int(0)), Int($0.int(1)))
        }
        out["embedding_chunk_rows"] = chunkRows.first?.0 ?? 0
        out["embedding_chunk_bytes"] = chunkRows.first?.1 ?? 0
        return out
    }

    // MARK: - Transcripts (encrypted at rest — same SQLCipher DB)

    public func saveTranscript(fileID: String, provider: String, segments: [TranscriptSegment]) throws {
        try atomically {
            try run("DELETE FROM transcripts WHERE file_id=?", binds: [.text(fileID)])
            try run("DELETE FROM transcripts_fts WHERE file_id=?", binds: [.text(fileID)])
            let now = Date().timeIntervalSince1970
            for seg in segments {
                try run("INSERT INTO transcripts(file_id, start, end, text, provider, created) VALUES(?,?,?,?,?,?)",
                        binds: [.text(fileID), .real(seg.start), .real(seg.end), .text(seg.text), .text(provider), .real(now)])
                if !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    try run("INSERT INTO transcripts_fts(file_id, text) VALUES(?,?)", binds: [.text(fileID), .text(seg.text)])
                }
            }
        }
    }

    public func transcripts(forFile id: String) throws -> [(start: Double, end: Double, text: String, provider: String)] {
        try query("SELECT start, end, text, provider FROM transcripts WHERE file_id=? ORDER BY start", binds: [.text(id)]) { r in
            (r.real(0), r.real(1), r.text(2) ?? "", r.text(3) ?? "")
        }
    }

    /// Cheap existence probe covering BOTH the segment rows and their FTS
    /// mirror — a transcript only "exists" while both agree. (Edge case: a
    /// transcript whose every segment is whitespace-only has segment rows but
    /// an empty FTS mirror, since blank text is never indexed.)
    public func transcriptExists(forFile id: String) throws -> Bool {
        let seg = try query("SELECT count(*) FROM transcripts WHERE file_id=?", binds: [.text(id)]) { $0.int(0) }
        let fts = try query("SELECT count(*) FROM transcripts_fts WHERE file_id=?", binds: [.text(id)]) { $0.int(0) }
        return (seg.first ?? 0) > 0 && (fts.first ?? 0) > 0
    }

    /// Remove a file's transcript rows and their FTS mirror.
    public func purgeTranscript(fileID: String) throws {
        try run("DELETE FROM transcripts WHERE file_id=?", binds: [.text(fileID)])
        try run("DELETE FROM transcripts_fts WHERE file_id=?", binds: [.text(fileID)])
    }

    /// Remove every derived content row for a file generation. Used when a
    /// path becomes a symlink/cloud placeholder so old evidence cannot remain
    /// queryable under the new non-readable identity.
    public func purgeDerivedData(fileID: String) throws {
        try transaction {
            for table in ["text_fts", "text_content", "classifications",
                          "screenshot_assessments", "visual_features",
                          "embeddings", "embedding_chunks", "transcripts",
                          "transcripts_fts", "exact_hashes"] {
                try txRun("DELETE FROM \(table) WHERE file_id=?", binds: [.text(fileID)])
            }
            try txRun(
                "DELETE FROM category_membership WHERE file_id=? AND source='classifier'",
                binds: [.text(fileID)])
            try txRun(
                "DELETE FROM review_inbox WHERE file_id=? AND state='open'",
                binds: [.text(fileID)])
        }
    }

    public func transcriptText(forFile id: String) throws -> String? {
        let rows = try transcripts(forFile: id)
        guard !rows.isEmpty else { return nil }
        return rows.map(\.text).joined(separator: " ")
    }

    /// Transaction-local variants for use inside Indexer commit.
    /// Replacement is atomic by construction: the previous generation's rows
    /// (and their FTS mirror) are deleted and the new generation's inserted
    /// inside one transaction, so no reader can observe a mixed state.
    public func txSaveTranscript(fileID: String, provider: String, segments: [TranscriptSegment]) throws {
        try txRun("DELETE FROM transcripts WHERE file_id=?", binds: [.text(fileID)])
        try txRun("DELETE FROM transcripts_fts WHERE file_id=?", binds: [.text(fileID)])
        let now = Date().timeIntervalSince1970
        for seg in segments {
            try txRun("INSERT INTO transcripts(file_id, start, end, text, provider, created) VALUES(?,?,?,?,?,?)",
                      binds: [.text(fileID), .real(seg.start), .real(seg.end), .text(seg.text), .text(provider), .real(now)])
            if !seg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try txRun("INSERT INTO transcripts_fts(file_id, text) VALUES(?,?)", binds: [.text(fileID), .text(seg.text)])
            }
        }
    }

    /// Verify the catalog is actually encrypted by checking the on-disk header.
    public static func onDiskHeaderIsPlaintextSQLite(path: String) -> Bool {
        guard let fh = FileHandle(forReadingAtPath: path),
              let hdr = try? fh.read(upToCount: 16), hdr.count >= 15 else { return false }
        fh.closeFile()
        return hdr.prefix(15) == Data("SQLite format 3".utf8)
    }
}
