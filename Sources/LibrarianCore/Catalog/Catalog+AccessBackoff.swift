import Foundation

extension Catalog {
    public struct AccessBackoffEntry: Sendable, Equatable {
        public let prefix: String
        public let reason: String
        public let attempts: Int
        public let lastAttempt: Double
        public let retryAfter: Double
    }

    private func ensureAccessBackoffTable() throws {
        try run("""
            CREATE TABLE IF NOT EXISTS access_backoff (
                prefix TEXT PRIMARY KEY,
                reason TEXT NOT NULL,
                attempts INTEGER NOT NULL,
                last_attempt REAL NOT NULL,
                retry_after REAL NOT NULL
            )
            """)
        try run("CREATE INDEX IF NOT EXISTS idx_access_backoff_retry ON access_backoff(retry_after)")
    }

    /// Record one row per inaccessible prefix. Repeated failures update that
    /// row with exponential backoff instead of appending one error per child.
    /// Oldest rows are pruned so pathological trees cannot create an unbounded
    /// permission cache.
    public func recordAccessBackoff(
        prefix: String,
        reason: String,
        now: Double = Date().timeIntervalSince1970,
        baseDelay: TimeInterval = 30,
        maximumDelay: TimeInterval = 30 * 60,
        maximumEntries: Int = 1_024
    ) throws {
        try ensureAccessBackoffTable()
        try transaction {
            let prior = try txQuery(
                "SELECT attempts FROM access_backoff WHERE prefix=?",
                binds: [.text(prefix)]) { Int($0.int(0)) }.first ?? 0
            let attempts = min(prior + 1, 30)
            let exponent = min(attempts - 1, 10)
            let delay = min(maximumDelay, baseDelay * pow(2, Double(exponent)))
            try txRun("""
                INSERT INTO access_backoff(prefix,reason,attempts,last_attempt,retry_after)
                VALUES(?,?,?,?,?)
                ON CONFLICT(prefix) DO UPDATE SET
                    reason=excluded.reason,
                    attempts=excluded.attempts,
                    last_attempt=excluded.last_attempt,
                    retry_after=excluded.retry_after
                """, binds: [
                    .text(prefix), .text(String(reason.prefix(120))), .int(Int64(attempts)),
                    .real(now), .real(now + delay)
                ])
            try txRun("""
                DELETE FROM access_backoff
                WHERE prefix IN (
                    SELECT prefix FROM access_backoff
                    ORDER BY last_attempt DESC
                    LIMIT -1 OFFSET ?
                )
                """, binds: [.int(Int64(max(1, maximumEntries)))])
        }
    }

    public func activeAccessBackoffEntries(
        now: Double = Date().timeIntervalSince1970,
        limit: Int = 1_024
    ) throws -> [AccessBackoffEntry] {
        try ensureAccessBackoffTable()
        return try query("""
            SELECT prefix,reason,attempts,last_attempt,retry_after
            FROM access_backoff
            WHERE retry_after>?
            ORDER BY retry_after,prefix
            LIMIT ?
            """, binds: [.real(now), .int(Int64(max(1, min(limit, 1_024))))]) { row in
            AccessBackoffEntry(prefix: row.text(0) ?? "",
                               reason: row.text(1) ?? "unreadable",
                               attempts: Int(row.int(2)),
                               lastAttempt: row.real(3),
                               retryAfter: row.real(4))
        }
    }

    public func accessBackoffEntries(limit: Int = 1_024) throws -> [AccessBackoffEntry] {
        try ensureAccessBackoffTable()
        return try query("""
            SELECT prefix,reason,attempts,last_attempt,retry_after
            FROM access_backoff
            ORDER BY last_attempt DESC,prefix
            LIMIT ?
            """, binds: [.int(Int64(max(1, min(limit, 1_024))))]) { row in
            AccessBackoffEntry(prefix: row.text(0) ?? "",
                               reason: row.text(1) ?? "unreadable",
                               attempts: Int(row.int(2)),
                               lastAttempt: row.real(3),
                               retryAfter: row.real(4))
        }
    }

    /// Manual rescan/reauthorization clears matching state so the source is
    /// retried immediately. If it is still inaccessible, enumeration records a
    /// fresh bounded backoff row during that same pass.
    public func clearAccessBackoff(atOrUnder root: String) throws {
        try ensureAccessBackoffTable()
        let normalized = root.count > 1 && root.hasSuffix("/")
            ? String(root.dropLast()) : root
        let descendant = normalized == "/" ? "/" : normalized + "/"
        try run("""
            DELETE FROM access_backoff
            WHERE prefix=? OR substr(prefix,1,length(?))=?
            """, binds: [.text(normalized), .text(descendant), .text(descendant)])
    }
}
