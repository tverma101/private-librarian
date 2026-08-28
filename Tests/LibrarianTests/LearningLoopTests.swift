import XCTest
@testable import LibrarianCore

/// Issue #20/#34: corrections -> deterministic, evidence-bound learned rules.
final class LearningLoopTests: XCTestCase {

    private func seedFile(_ cat: Catalog, id: String, path: String) throws {
        try cat.run("""
            INSERT INTO files(id, path, volume_uuid, fs_file_id, size, mtime, ctime, kind, status, first_seen, last_extractor)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, binds: [.text(id), .text(path), .text("volume"), .int(Int64(id.hashValue)),
                           .int(10), .real(100), .real(100), .text("text"), .text("indexed"),
                           .real(100), .text("index-v1")])
    }

    private func recordPathCorrection(_ cat: Catalog, id: String, category: String,
                                      action: CorrectionAction = .addCategory,
                                      pattern: String = "extra") throws {
        try cat.recordCorrection(fileID: id, category: category, action: action,
                                 patternType: .pathKeyword, pattern: pattern)
    }

    func testRecordCorrection() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        try cat.recordCorrection(fileID: "file_1", category: "School/Extra", action: .addCategory)
        // Promote not yet: only 1 correction, need 3
        let promoted = try cat.promoteIfNeeded(patternType: .pathKeyword, pattern: "extra", targetCategory: "School/Extra")
        XCTAssertNil(promoted, "should not promote before 3 corrections")
        let rules = try cat.listRules()
        XCTAssertTrue(rules.isEmpty)
    }

    func testThreeUnrelatedCategoryCorrectionsDoNotPromoteArbitraryPattern() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        for (id, category) in [("file_a", "School/A"), ("file_b", "School/B"), ("file_c", "School/C")] {
            try seedFile(cat, id: id, path: "/tmp/extra-\(id).txt")
            try recordPathCorrection(cat, id: id, category: category)
        }
        let rule = try cat.promoteIfNeeded(patternType: .pathKeyword, pattern: "extra", targetCategory: "School/Extra")
        XCTAssertNil(rule)
        XCTAssertTrue(try cat.listRules().isEmpty)
    }

    func testThreeRemovalsDoNotPromoteAddRule() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        for id in ["file_a", "file_b", "file_c"] {
            try seedFile(cat, id: id, path: "/tmp/extra-\(id).txt")
            try recordPathCorrection(cat, id: id, category: "School/Extra", action: .removeCategory)
        }
        XCTAssertNil(try cat.promoteIfNeeded(patternType: .pathKeyword, pattern: " EXTRA ", targetCategory: "School/Extra"))
        XCTAssertTrue(try cat.listRules().isEmpty)
    }

    func testThreeMatchingPositiveCorrectionsPromote() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        for id in ["file_a", "file_b", "file_c"] {
            try seedFile(cat, id: id, path: "/tmp/extra-\(id).txt")
            try recordPathCorrection(cat, id: id, category: "School/Extra")
        }
        let evidenceRows = try cat.query("SELECT count(*), count(pattern), count(generation) FROM corrections") {
            ($0.int(0), $0.int(1), $0.int(2))
        }.first
        XCTAssertEqual(evidenceRows?.0, 3)
        XCTAssertEqual(evidenceRows?.1, 3)
        XCTAssertEqual(evidenceRows?.2, 3)
        let rule = try cat.promoteIfNeeded(patternType: .pathKeyword, pattern: " EXTRA ", targetCategory: "School/Extra")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.pattern, "extra")
        XCTAssertEqual(rule?.targetCategory, "School/Extra")
        XCTAssertEqual(rule?.enabled, false, "promoted rule must be disabled by default (reversible)")
        XCTAssertEqual(try cat.listRules().count, 1)
        // Enabling should be required for effect
        let ev = EvidenceExtractor.Evidence(filenameTokens: ["extra", "notes"], kind: "text", sizeClass: "small")
        let engineDisabled = LearnedRuleEngine(rules: try cat.listRules())
        let r0 = engineDisabled.enrich(categories: ["Documents/Text"], evidence: ev, path: "/tmp/extra_notes.txt")
        XCTAssertFalse(r0.categories.contains("School/Extra"), "disabled rule must not fire")
        XCTAssertTrue(r0.reasons.isEmpty)
    }

    func testMixedNegativeEvidenceBlocksExistingRule() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        for id in ["file_a", "file_b", "file_c", "file_d"] {
            try seedFile(cat, id: id, path: "/tmp/extra-\(id).txt")
        }
        for id in ["file_a", "file_b", "file_c"] {
            try recordPathCorrection(cat, id: id, category: "School/Extra")
        }
        guard let rule = try cat.promoteIfNeeded(patternType: .pathKeyword,
                                                  pattern: "extra",
                                                  targetCategory: "School/Extra") else {
            return XCTFail("positive evidence should promote")
        }
        try cat.setRuleEnabled(id: rule.id, enabled: true)
        try recordPathCorrection(cat, id: "file_d", category: "School/Extra", action: .removeCategory)
        XCTAssertNil(try cat.promoteIfNeeded(patternType: .pathKeyword,
                                             pattern: "EXTRA",
                                             targetCategory: "School/Extra"))
        let stored = try cat.listRules()
        XCTAssertEqual(stored.count, 1)
        XCTAssertFalse(stored[0].enabled, "negative evidence must disable the rule")
        XCTAssertEqual(stored[0].confidence, 0.35, accuracy: 1e-9)
    }

    func testReviewCorrectionFeedsEvidenceBoundPromotion() throws {
        let cat = try TestSupport.makeCatalog()
        for id in ["file_a", "file_b", "file_c"] {
            try seedFile(cat, id: id, path: "/tmp/review-\(id).txt")
            try cat.applyReviewCorrection(fileID: id, category: "School/Notes", action: .addCategory)
        }
        let corrections = try cat.query(
            "SELECT count(*), count(pattern), count(generation) FROM corrections") {
                ($0.int(0), $0.int(1), $0.int(2))
            }.first
        XCTAssertEqual(corrections?.0, 3)
        XCTAssertEqual(corrections?.1, 3)
        XCTAssertEqual(corrections?.2, 3)
        let rules = try cat.listRules()
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].patternType, .extension)
        XCTAssertEqual(rules[0].pattern, "txt")
        XCTAssertEqual(rules[0].targetCategory, "School/Notes")
        XCTAssertFalse(rules[0].enabled)
    }

    func testDisableDeletesEffect() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        // Need a file row so setRuleEnabled's invalidation path has something to enqueue/clear
        // and enrichment has a realistic evidence path
        // Use extension pattern for deterministic test.
        for id in ["file_x", "file_y", "file_z"] {
            try seedFile(cat, id: id, path: "/tmp/photo-\(id).cr2")
            try cat.recordCorrection(fileID: id, category: "Image/Raw", action: .addCategory,
                                     patternType: .extension, pattern: ".CR2")
        }
        guard let rule = try cat.promoteIfNeeded(patternType: .extension, pattern: "cr2", targetCategory: "Image/Raw") else {
            return XCTFail("promotion failed")
        }
        // Enable -> should fire on .cr2 files
        try cat.setRuleEnabled(id: rule.id, enabled: true)
        var enabled = try cat.enabledRules()
        XCTAssertEqual(enabled.count, 1)
        let ev = EvidenceExtractor.Evidence(filenameTokens: ["photo"], kind: "image", sizeClass: "large")
        let eng = LearnedRuleEngine(rules: enabled)
        let hit = eng.enrich(categories: ["Image"], evidence: ev, path: "/tmp/photo.CR2")
        XCTAssertTrue(hit.categories.contains("Image/Raw"))
        XCTAssertFalse(hit.reasons.isEmpty, "firing reason must be inspectable")
        // Disable -> effect disappears
        try cat.setRuleEnabled(id: rule.id, enabled: false)
        enabled = try cat.enabledRules()
        XCTAssertTrue(enabled.isEmpty)
        let eng2 = LearnedRuleEngine(rules: enabled)
        let miss = eng2.enrich(categories: ["Image"], evidence: ev, path: "/tmp/photo.CR2")
        XCTAssertFalse(miss.categories.contains("Image/Raw"))
        XCTAssertTrue(miss.reasons.isEmpty)
    }

    func testRuleToggleReclassifiesWithoutRepeatingExtractionWork() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learning-classification-only-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = (0..<3).map { root.appendingPathComponent("image-\($0).png") }
        for path in paths {
            try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                .write(to: path)
        }

        let cat = try TestSupport.makeCatalog()
        var options = Indexer.Options()
        options.enableOCR = true
        let indexer = Indexer(broker: SourceBroker(), catalog: cat,
                              scheduler: Scheduler(), options: options)
        XCTAssertEqual(try indexer.indexRoot(root), 3)
        let rows = try cat.allFiles().filter { $0.path.hasSuffix(".png") }
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            try cat.recordCorrection(fileID: row.id, category: "Image/Raw",
                                     action: .addCategory,
                                     patternType: .extension, pattern: "PNG")
        }
        guard let rule = try cat.promoteIfNeeded(patternType: .extension,
                                                 pattern: "png",
                                                 targetCategory: "Image/Raw") else {
            return XCTFail("matching image corrections should promote a rule")
        }
        try cat.setRuleEnabled(id: rule.id, enabled: true)
        indexer.resetWorkMetrics()

        XCTAssertEqual(try indexer.indexRoot(root), 3)
        XCTAssertEqual(indexer.workMetrics, Indexer.WorkMetrics(),
                       "a rule toggle must not rerun OCR, Vision, embeddings, or hashing")
        let memberships = try cat.categoryMemberships()
        XCTAssertTrue(rows.allSatisfy { row in
            memberships.contains { $0.categoryPath == "Image/Raw" && $0.fileID == row.id }
        })
        XCTAssertTrue(try cat.learnedReindexQueue().isEmpty)
    }
}
