import Foundation

// MARK: - Learned tables + helpers (Issue #20)

public extension Catalog {

    func ensureLearnedTables() throws {
        try run("""
        CREATE TABLE IF NOT EXISTS corrections (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            file_id TEXT NOT NULL,
            category TEXT NOT NULL,
            action TEXT NOT NULL,
            created REAL NOT NULL,
            provenance TEXT NOT NULL
        );
        """)
        try run("CREATE INDEX IF NOT EXISTS idx_corrections_file ON corrections(file_id);")
        try run("""
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
        """)
        try run("CREATE UNIQUE INDEX IF NOT EXISTS idx_learned_rules_unique ON learned_rules(pattern_type, pattern, target_category);")
        try run("""
        CREATE TABLE IF NOT EXISTS learned_reindex_queue (
            file_id TEXT PRIMARY KEY,
            enqueued REAL NOT NULL
        );
        """)
    }

    func recordCorrection(fileID: String, category: String, action: CorrectionAction, provenance: String = "user") throws {
        try ensureLearnedTables()
        try run("INSERT INTO corrections(file_id, category, action, created, provenance) VALUES(?,?,?,?,?)",
                binds: [.text(fileID), .text(category), .text(action.rawValue), .real(Date().timeIntervalSince1970), .text(provenance)])
    }

    func listRules() throws -> [LearnedRule] {
        try ensureLearnedTables()
        return try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules ORDER BY id ASC") { r in
            LearnedRule(
                id: r.int(0),
                patternType: LearnedPatternType(rawValue: r.text(1) ?? "pathKeyword") ?? .pathKeyword,
                pattern: r.text(2) ?? "",
                targetCategory: r.text(3) ?? "",
                confidence: r.real(4),
                enabled: r.int(5) != 0,
                provenance: r.text(6) ?? "",
                created: r.real(7)
            )
        }
    }

    func enabledRules() throws -> [LearnedRule] {
        try ensureLearnedTables()
        return try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules WHERE enabled!=0 ORDER BY id ASC") { r in
            LearnedRule(
                id: r.int(0),
                patternType: LearnedPatternType(rawValue: r.text(1) ?? "pathKeyword") ?? .pathKeyword,
                pattern: r.text(2) ?? "",
                targetCategory: r.text(3) ?? "",
                confidence: r.real(4),
                enabled: r.int(5) != 0,
                provenance: r.text(6) ?? "",
                created: r.real(7)
            )
        }
    }

    func setRuleEnabled(id: Int64, enabled: Bool) throws {
        try ensureLearnedTables()
        try run("UPDATE learned_rules SET enabled=? WHERE id=?", binds: [.int(enabled ? 1 : 0), .int(id)])
        // Invalidate only affected files: those whose path matches the rule's pattern.
        let row = try query("SELECT pattern_type, pattern FROM learned_rules WHERE id=?", binds: [.int(id)]) { r in (r.text(0) ?? "", r.text(1) ?? "") }
        guard let (pt, pat) = row.first, !pat.isEmpty else { return }
        let lcPat = pat.lowercased()
        for f in try allFiles() {
            var match = false
            if pt == LearnedPatternType.extension.rawValue {
                let ext = (f.path as NSString).pathExtension.lowercased()
                let needle = lcPat.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                match = (ext == needle || ext.hasSuffix(needle))
            } else if pt == LearnedPatternType.pathKeyword.rawValue {
                match = f.path.lowercased().contains(lcPat)
            } else {
                match = true // metadata: conservatively all
            }
            if match {
                try? run("INSERT OR REPLACE INTO learned_reindex_queue(file_id, enqueued) VALUES(?,?)",
                         binds: [.text(f.id), .real(Date().timeIntervalSince1970)])
                try? run("UPDATE files SET last_extractor='' WHERE id=?", binds: [.text(f.id)])
            }
        }
    }

    /// Promote to a disabled-by-default rule when >= threshold corrections exist for targetCategory.
    /// Pattern is caller-supplied (deterministic): the caller groups corrections by the pattern they intend to learn.
    /// Idempotent: if the rule already exists, returns it without duplicating.
    @discardableResult
    func promoteIfNeeded(patternType: LearnedPatternType, pattern: String, targetCategory: String, provenance: String = "promoted", threshold: Int = 3) throws -> LearnedRule? {
        try ensureLearnedTables()
        let normPat = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normPat.isEmpty else { return nil }
        // Count corrections for this targetCategory (action addCategory or wrongCategory both count as signal).
        let cnt = try query("SELECT count(*) FROM corrections WHERE lower(category)=?", binds: [.text(targetCategory.lowercased())]) { $0.int(0) }.first ?? 0
        guard cnt >= Int64(threshold) else { return nil }
        let existing = try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules WHERE pattern_type=? AND lower(pattern)=? AND lower(target_category)=?",
                                 binds: [.text(patternType.rawValue), .text(normPat), .text(targetCategory.lowercased())]) { r in
            LearnedRule(id: r.int(0), patternType: LearnedPatternType(rawValue: r.text(1) ?? "") ?? patternType,
                        pattern: r.text(2) ?? "", targetCategory: r.text(3) ?? "",
                        confidence: r.real(4), enabled: r.int(5) != 0, provenance: r.text(6) ?? "", created: r.real(7))
        }
        if let e = existing.first { return e }
        try run("INSERT OR IGNORE INTO learned_rules(pattern_type, pattern, target_category, confidence, enabled, provenance, created) VALUES(?,?,?,?,?,?,?)",
                binds: [.text(patternType.rawValue), .text(normPat), .text(targetCategory), .real(0.55), .int(0), .text(provenance), .real(Date().timeIntervalSince1970)])
        let rows = try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules WHERE pattern_type=? AND lower(pattern)=? AND lower(target_category)=?",
                             binds: [.text(patternType.rawValue), .text(normPat), .text(targetCategory.lowercased())]) { r in
            LearnedRule(id: r.int(0), patternType: LearnedPatternType(rawValue: r.text(1) ?? "") ?? patternType,
                        pattern: r.text(2) ?? "", targetCategory: r.text(3) ?? "",
                        confidence: r.real(4), enabled: r.int(5) != 0, provenance: r.text(6) ?? "", created: r.real(7))
        }
        return rows.first
    }

    func learnedReindexQueue() throws -> [String] {
        try ensureLearnedTables()
        return try query("SELECT file_id FROM learned_reindex_queue") { $0.text(0) ?? "" }
    }

    func clearLearnedReindexQueueEntry(fileID: String) throws {
        try run("DELETE FROM learned_reindex_queue WHERE file_id=?", binds: [.text(fileID)])
    }
}
