import XCTest
@testable import LibrarianCore

/// Issue #20: corrections -> deterministic learned rules.
/// Three tests: record, promotion after 3x, disable deletes effect.
final class LearningLoopTests: XCTestCase {

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

    func testPromotionAfterThreeCorrections() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        try cat.recordCorrection(fileID: "file_a", category: "School/Extra", action: .addCategory)
        try cat.recordCorrection(fileID: "file_b", category: "School/Extra", action: .addCategory)
        try cat.recordCorrection(fileID: "file_c", category: "School/Extra", action: .addCategory)
        let rule = try cat.promoteIfNeeded(patternType: .pathKeyword, pattern: "extra", targetCategory: "School/Extra")
        XCTAssertNotNil(rule)
        XCTAssertEqual(rule?.pattern, "extra")
        XCTAssertEqual(rule?.targetCategory, "School/Extra")
        XCTAssertEqual(rule?.enabled, false, "promoted rule must be disabled by default (reversible)")
        let listed = try cat.listRules()
        XCTAssertEqual(listed.count, 1)
        // Enabling should be required for effect
        let ev = EvidenceExtractor.Evidence(filenameTokens: ["extra", "notes"], kind: "text", sizeClass: "small")
        let engineDisabled = LearnedRuleEngine(rules: listed)
        let r0 = engineDisabled.enrich(categories: ["Documents/Text"], evidence: ev, path: "/tmp/extra_notes.txt")
        XCTAssertFalse(r0.categories.contains("School/Extra"), "disabled rule must not fire")
        XCTAssertTrue(r0.reasons.isEmpty)
    }

    func testDisableDeletesEffect() throws {
        let cat = try TestSupport.makeCatalog()
        try cat.ensureLearnedTables()
        // Need a file row so setRuleEnabled's invalidation path has something to enqueue/clear
        // and enrichment has a realistic evidence path
        // Use extension pattern for deterministic test.
        try cat.recordCorrection(fileID: "file_x", category: "Image/Raw", action: .addCategory)
        try cat.recordCorrection(fileID: "file_y", category: "Image/Raw", action: .addCategory)
        try cat.recordCorrection(fileID: "file_z", category: "Image/Raw", action: .addCategory)
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
}
