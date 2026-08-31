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

        // Existing encrypted catalogs created before evidence-bound learning
        // remain readable. Nullable columns quarantine legacy corrections from
        // promotion until a new correction records current-file evidence.
        for column in ["pattern_type", "pattern", "generation"] {
            let present = try query("SELECT 1 FROM pragma_table_info('corrections') WHERE name=?", binds: [.text(column)]) { _ in 1 }.first != nil
            if !present {
                try run("ALTER TABLE corrections ADD COLUMN \(column) TEXT")
            }
        }
        try run("CREATE INDEX IF NOT EXISTS idx_corrections_evidence ON corrections(pattern_type, pattern, category, action, generation)")
    }

    func recordCorrection(fileID: String, category: String, action: CorrectionAction, provenance: String = "user") throws {
        try ensureLearnedTables()
        // Compatibility path for callers that do not provide deterministic
        // pattern evidence. It is intentionally non-promoting.
        try run("INSERT INTO corrections(file_id, category, action, created, provenance) VALUES(?,?,?,?,?)",
                binds: [.text(fileID), .text(category), .text(action.rawValue), .real(Date().timeIntervalSince1970), .text(provenance)])
    }

    /// Record a correction with evidence captured from the current catalog
    /// generation. Evidence is retained only when it matches the corrected
    /// file, so callers cannot attach an arbitrary pattern to unrelated files.
    func recordCorrection(fileID: String, category: String, action: CorrectionAction,
                          patternType: LearnedPatternType, pattern: String,
                          provenance: String = "user") throws {
        try ensureLearnedTables()
        let normalizedPattern = Self.normalizeLearningPattern(pattern, type: patternType)
        let normalizedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPattern.isEmpty,
              let evidence = try learningEvidence(fileID: fileID),
              Self.patternMatches(patternType: patternType, pattern: normalizedPattern,
                                  path: evidence.path, metadata: evidence.metadata) else {
            try recordCorrection(fileID: fileID, category: category, action: action, provenance: provenance)
            return
        }
        try run("""
            INSERT INTO corrections(file_id, category, action, pattern_type, pattern, generation, created, provenance)
            VALUES(?,?,?,?,?,?,?,?)
            """, binds: [.text(fileID), .text(normalizedCategory), .text(action.rawValue),
                           .text(patternType.rawValue), .text(normalizedPattern), .text(evidence.generation),
                           .real(Date().timeIntervalSince1970), .text(provenance)])
    }

    /// Record the deterministic evidence associated with a review correction.
    /// This transaction-local API lets Catalog.applyReviewCorrection persist
    /// the correction atomically with the catalog-only membership override.
    @discardableResult
    func txRecordReviewCorrection(fileID: String, category: String,
                                  action: ReviewCorrectionAction,
                                  provenance: String = "review-ui")
        throws -> (patternType: LearnedPatternType, pattern: String)? {
        let correctionAction: CorrectionAction
        switch action {
        case .addCategory: correctionAction = .addCategory
        case .removeCategory: correctionAction = .removeCategory
        case .markUnknown: correctionAction = .markUnknown
        }
        guard let evidence = try txLearningEvidence(fileID: fileID) else {
            try txRun(
                "INSERT INTO corrections(file_id, category, action, created, provenance) VALUES(?,?,?,?,?)",
                binds: [.text(fileID), .text(category), .text(correctionAction.rawValue),
                        .real(Date().timeIntervalSince1970), .text(provenance)])
            return nil
        }

        guard let candidate = Self.learningPattern(for: evidence) else {
            try txRun(
                "INSERT INTO corrections(file_id, category, action, created, provenance) VALUES(?,?,?,?,?)",
                binds: [.text(fileID), .text(category), .text(correctionAction.rawValue),
                        .real(Date().timeIntervalSince1970), .text(provenance)])
            return nil
        }

        try txRun("""
            INSERT INTO corrections(file_id, category, action, pattern_type, pattern, generation, created, provenance)
            VALUES(?,?,?,?,?,?,?,?)
            """, binds: [
                .text(fileID), .text(category), .text(correctionAction.rawValue),
                .text(candidate.patternType.rawValue), .text(candidate.pattern),
                .text(evidence.generation), .real(Date().timeIntervalSince1970),
                .text(provenance)
            ])
        return candidate
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
        // The rule flip and its invalidation set must be one catalog event.
        // Indexing can observe the database between public calls, so doing the
        // UPDATE, match lookup, queue insert, and extractor invalidation as
        // separate writes could let a run use the new rule while still
        // believing old classifications are current.
        try transaction {
            try txRun("UPDATE learned_rules SET enabled=? WHERE id=?",
                      binds: [.int(enabled ? 1 : 0), .int(id)])
            let rows = try txQuery(
                "SELECT pattern_type, pattern FROM learned_rules WHERE id=?",
                binds: [.int(id)]) { r in
                    (r.text(0) ?? "", r.text(1) ?? "")
                }
            guard let (pt, pat) = rows.first, !pat.isEmpty else { return }
            let lcPat = pat.lowercased()
            let files = try txQuery(
                "SELECT id, path FROM files WHERE status != 'unscoped'") { r in
                    (r.text(0) ?? "", r.text(1) ?? "")
                }
            let now = Date().timeIntervalSince1970
            for (fileID, path) in files {
                let match: Bool
                if pt == LearnedPatternType.extension.rawValue {
                    let ext = (path as NSString).pathExtension.lowercased()
                    let needle = lcPat.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    match = (ext == needle || ext.hasSuffix(needle))
                } else if pt == LearnedPatternType.pathKeyword.rawValue {
                    match = path.lowercased().contains(lcPat)
                } else {
                    match = true // metadata: conservatively all
                }
                guard match else { continue }
                try txRun(
                    "INSERT OR REPLACE INTO learned_reindex_queue(file_id, enqueued) VALUES(?,?)",
                    binds: [.text(fileID), .real(now)])
                try txRun(
                    "UPDATE files SET last_extractor='' WHERE id=?",
                    binds: [.text(fileID)])
            }
        }
    }

    /// Delete a learned rule and invalidate only files it could have affected.
    func deleteRule(id: Int64) throws {
        try ensureLearnedTables()
        let exists = try query("SELECT count(*) FROM learned_rules WHERE id=?", binds: [.int(id)]) { $0.int(0) }.first ?? 0
        guard exists > 0 else { return }
        try setRuleEnabled(id: id, enabled: false)
        try run("DELETE FROM learned_rules WHERE id=?", binds: [.int(id)])
    }

    /// Promote to a disabled-by-default rule when >= threshold distinct files
    /// provide the same normalized pattern/category evidence. Only additive
    /// corrections support promotion; negative corrections block it.
    /// Idempotent: if the rule already exists, returns it without duplicating.
    @discardableResult
    func promoteIfNeeded(patternType: LearnedPatternType, pattern: String, targetCategory: String, provenance: String = "promoted", threshold: Int = 3) throws -> LearnedRule? {
        try ensureLearnedTables()
        let normPat = Self.normalizeLearningPattern(pattern, type: patternType)
        let normCategory = targetCategory.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normPat.isEmpty, !normCategory.isEmpty else { return nil }

        let negativeCount = try query("""
            SELECT count(*) FROM corrections
            WHERE pattern_type=? AND lower(pattern)=? AND lower(category)=?
              AND generation IS NOT NULL AND action IN (?,?)
            """, binds: [.text(patternType.rawValue), .text(normPat), .text(normCategory),
                           .text(CorrectionAction.removeCategory.rawValue), .text(CorrectionAction.wrongCategory.rawValue)]) { $0.int(0) }.first ?? 0

        let existing = try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules WHERE pattern_type=? AND lower(pattern)=? AND lower(target_category)=?",
                                 binds: [.text(patternType.rawValue), .text(normPat), .text(normCategory)]) { r in
            LearnedRule(id: r.int(0), patternType: LearnedPatternType(rawValue: r.text(1) ?? "") ?? patternType,
                        pattern: r.text(2) ?? "", targetCategory: r.text(3) ?? "",
                        confidence: r.real(4), enabled: r.int(5) != 0, provenance: r.text(6) ?? "", created: r.real(7))
        }.first
        if negativeCount > 0 {
            if let existing {
                let reduced = max(0, existing.confidence - 0.20)
                try run("UPDATE learned_rules SET confidence=?, enabled=0, provenance=? WHERE id=?",
                        binds: [.real(reduced), .text(provenance + ":blocked-negative"), .int(existing.id)])
            }
            return nil
        }

        let cnt = try query("""
            SELECT count(DISTINCT file_id) FROM corrections
            WHERE pattern_type=? AND lower(pattern)=? AND lower(category)=?
              AND generation IS NOT NULL AND action=?
            """, binds: [.text(patternType.rawValue), .text(normPat), .text(normCategory),
                           .text(CorrectionAction.addCategory.rawValue)]) { $0.int(0) }.first ?? 0
        guard cnt >= Int64(threshold) else { return nil }
        if let existing { return existing }
        try run("INSERT OR IGNORE INTO learned_rules(pattern_type, pattern, target_category, confidence, enabled, provenance, created) VALUES(?,?,?,?,?,?,?)",
                binds: [.text(patternType.rawValue), .text(normPat), .text(targetCategory), .real(0.55), .int(0), .text(provenance), .real(Date().timeIntervalSince1970)])
        let rows = try query("SELECT id, pattern_type, pattern, target_category, confidence, enabled, provenance, created FROM learned_rules WHERE pattern_type=? AND lower(pattern)=? AND lower(target_category)=?",
                             binds: [.text(patternType.rawValue), .text(normPat), .text(normCategory)]) { r in
            LearnedRule(id: r.int(0), patternType: LearnedPatternType(rawValue: r.text(1) ?? "") ?? patternType,
                        pattern: r.text(2) ?? "", targetCategory: r.text(3) ?? "",
                        confidence: r.real(4), enabled: r.int(5) != 0, provenance: r.text(6) ?? "", created: r.real(7))
        }
        return rows.first
    }

    private struct LearningEvidence {
        let path: String
        let generation: String
        let metadata: [String]
    }

    private func learningEvidence(fileID: String) throws -> LearningEvidence? {
        let rows = try query("""
            SELECT path, volume_uuid, fs_file_id, size, mtime, ctime, COALESCE(last_extractor, '')
            FROM files WHERE id=?
            """, binds: [.text(fileID)]) { r in
            (r.text(0) ?? "", r.text(1) ?? "", r.int(2), r.int(3), r.real(4), r.real(5), r.text(6) ?? "")
        }
        guard let row = rows.first else { return nil }
        let generation = [fileID, row.1, String(row.2), String(row.3), String(row.4), String(row.5), row.6].joined(separator: "|")
        let metadata = try query("SELECT k || '=' || v FROM metadata WHERE file_id=?", binds: [.text(fileID)]) { $0.text(0) ?? "" }
        return LearningEvidence(path: row.0, generation: generation, metadata: metadata)
    }

    private func txLearningEvidence(fileID: String) throws -> LearningEvidence? {
        let rows = try txQuery("""
            SELECT path, volume_uuid, fs_file_id, size, mtime, ctime, COALESCE(last_extractor, '')
            FROM files WHERE id=?
            """, binds: [.text(fileID)]) { r in
            (r.text(0) ?? "", r.text(1) ?? "", r.int(2), r.int(3), r.real(4), r.real(5), r.text(6) ?? "")
        }
        guard let row = rows.first else { return nil }
        let generation = [fileID, row.1, String(row.2), String(row.3), String(row.4), String(row.5), row.6].joined(separator: "|")
        let metadata = try txQuery("SELECT k || '=' || v FROM metadata WHERE file_id=?", binds: [.text(fileID)]) { $0.text(0) ?? "" }
        return LearningEvidence(path: row.0, generation: generation, metadata: metadata)
    }

    private static func learningPattern(for evidence: LearningEvidence)
        -> (patternType: LearnedPatternType, pattern: String)? {
        let path = evidence.path
        let components = path.split(separator: "/").map(String.init)
        if let parent = components.dropLast().last {
            let normalized = normalizeLearningPattern(parent, type: .pathKeyword)
            let generic = Set(["", "tmp", "private", "var", "users", "documents", "desktop", "downloads"])
            if normalized.count >= 2, !generic.contains(normalized) {
                return (.pathKeyword, normalized)
            }
        }

        let ext = (path as NSString).pathExtension
        let normalizedExtension = normalizeLearningPattern(ext, type: .extension)
        guard !normalizedExtension.isEmpty else { return nil }
        return (.extension, normalizedExtension)
    }

    private static func normalizeLearningPattern(_ pattern: String, type: LearnedPatternType) -> String {
        let compact = pattern.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if type == .extension {
            return compact.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return compact
    }

    private static func patternMatches(patternType: LearnedPatternType, pattern: String,
                                       path: String, metadata: [String]) -> Bool {
        switch patternType {
        case .extension:
            let ext = (path as NSString).pathExtension.lowercased()
            let needle = pattern.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return !needle.isEmpty && (ext == needle || ext.hasSuffix(needle))
        case .pathKeyword:
            return path.lowercased().contains(pattern)
        case .metadata:
            return metadata.joined(separator: " ").lowercased().contains(pattern)
        }
    }

    func learnedReindexQueue() throws -> [String] {
        try ensureLearnedTables()
        return try query("SELECT file_id FROM learned_reindex_queue") { $0.text(0) ?? "" }
    }

    func learnedReindexEntries() throws -> [(fileID: String, path: String)] {
        try ensureLearnedTables()
        return try query("""
            SELECT q.file_id, f.path
            FROM learned_reindex_queue q
            JOIN files f ON f.id = q.file_id
            ORDER BY q.file_id
            """) { ($0.text(0) ?? "", $0.text(1) ?? "") }
    }

    func clearLearnedReindexQueueEntry(fileID: String) throws {
        try run("DELETE FROM learned_reindex_queue WHERE file_id=?", binds: [.text(fileID)])
    }
}
