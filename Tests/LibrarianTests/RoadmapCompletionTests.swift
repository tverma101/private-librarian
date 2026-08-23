import XCTest
@testable import LibrarianCore

/// Issue #25/#26/#29 regression coverage. All checks use synthetic catalog
/// rows and temporary source trees; the source side remains read-only.
final class RoadmapCompletionTests: XCTestCase {
    private func seedFile(_ catalog: Catalog, id: String, path: String, status: String = "indexed") throws {
        try catalog.run("""
            INSERT INTO files(id, path, volume_uuid, fs_file_id, size, mtime, ctime, kind, status, first_seen, last_extractor)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, binds: [.text(id), .text(path), .text("volume"), .int(1), .int(4),
                           .real(100), .real(100), .text("text"), .text(status),
                           .real(100), .text("roadmap-test")])
    }

    func testReviewInboxAndOneClickCorrectionAreCatalogOnly() throws {
        let catalog = try TestSupport.makeCatalog()
        let source = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("roadmap-review-\(UUID().uuidString).txt")
        let original = Data("private source bytes".utf8)
        try original.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        try seedFile(catalog, id: "file_review", path: source.path)
        try catalog.saveClassification(Classification(fileID: "file_review", categories: ["Documents/Text"],
                                                       description: "text", confidence: 0.40,
                                                       reasonCodes: ["weak-signal"]), classifier: "test")

        let items = try catalog.reviewItems()
        XCTAssertEqual(items.map(\.fileID), ["file_review"])
        try catalog.applyReviewCorrection(fileID: "file_review", category: "School/CSC-151", action: .addCategory)
        XCTAssertTrue(try catalog.reviewItems().isEmpty)
        let memberships = try catalog.categoryMemberships()
        XCTAssertTrue(memberships.contains { $0.categoryPath == "School/CSC-151" && $0.fileID == "file_review" })
        XCTAssertEqual(try Data(contentsOf: source), original)

        // The override survives a classifier refresh and prevents a removed
        // category from being silently reintroduced.
        try catalog.applyReviewCorrection(fileID: "file_review", category: "Documents/Text", action: .removeCategory)
        try catalog.saveClassification(Classification(fileID: "file_review", categories: ["Documents/Text"],
                                                       description: "text", confidence: 0.90,
                                                       reasonCodes: ["strong-signal"]), classifier: "test")
        let refreshed = try catalog.categoryMemberships()
        XCTAssertFalse(refreshed.contains { $0.categoryPath == "Documents/Text" && $0.fileID == "file_review" })
    }

    func testOrganizationGraphPreservesMultiLabelMemberships() throws {
        let catalog = try TestSupport.makeCatalog()
        try seedFile(catalog, id: "file_graph", path: "/tmp/graph.txt")
        try catalog.saveClassification(Classification(fileID: "file_graph",
                                                       categories: ["School/CSC-151", "Screenshot"],
                                                       description: "text", confidence: 0.9,
                                                       reasonCodes: ["test"]), classifier: "test")
        let snapshot = try catalog.refreshOrganizationGraph()
        let fileNode = OrganizationGraphBuilder.fileNodeID("file_graph")
        let categoryEdges = snapshot.edges.filter { $0.sourceID == fileNode && $0.relation == .category }
        XCTAssertEqual(categoryEdges.map(\.targetID), ["category:School/CSC-151", "category:Screenshot"])
        XCTAssertTrue(snapshot.nodes.contains { $0.id == "category:School/CSC-151" })
        XCTAssertEqual(try catalog.organizationEdges(), snapshot.edges)
    }

    func testExcludedRootsAreSkippedWithoutMarkingExistingRowsMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("roadmap-exclusion-\(UUID().uuidString)")
        let excluded = root.appendingPathComponent("Private")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        let includedFile = root.appendingPathComponent("visible.txt")
        let excludedFile = excluded.appendingPathComponent("secret.txt")
        try Data("visible".utf8).write(to: includedFile)
        try Data("secret".utf8).write(to: excludedFile)
        defer { try? FileManager.default.removeItem(at: root) }

        let listed = try SourceBroker.enumerate(root: root, excludedPrefixes: [excluded.path])
        XCTAssertTrue(listed.contains { $0.path == includedFile.path })
        XCTAssertFalse(listed.contains { $0.path.hasPrefix(excluded.path + "/") })

        let catalog = try TestSupport.makeCatalog()
        var options = Indexer.Options()
        options.excludedPaths = [excluded.path]
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options)
        _ = try indexer.indexRoot(root)
        let files = try catalog.allFiles()
        XCTAssertTrue(files.contains { $0.path == includedFile.path })
        XCTAssertFalse(files.contains { $0.path == excludedFile.path })
    }

    func testCoverageAndDashboardReportCatalogState() throws {
        let catalog = try TestSupport.makeCatalog()
        try seedFile(catalog, id: "file_indexed", path: "/tmp/coverage/indexed.txt")
        try seedFile(catalog, id: "file_missing", path: "/tmp/coverage/missing.txt", status: "missing")
        try catalog.saveClassification(Classification(fileID: "file_indexed", categories: ["Documents/Text"],
                                                       description: "text", confidence: 0.9,
                                                       reasonCodes: []), classifier: "test")
        try catalog.saveClassification(Classification(fileID: "file_missing", categories: ["Review"],
                                                       description: "unknown", confidence: 0.2,
                                                       reasonCodes: ["unknown"]), classifier: "test")
        let coverage = try catalog.coverage(roots: ["/tmp/coverage"])
        XCTAssertEqual(coverage.catalogedFiles, 2)
        XCTAssertEqual(coverage.indexedFiles, 1)
        XCTAssertEqual(coverage.missingFiles, 1)
        let dashboard = try catalog.dashboard()
        XCTAssertEqual(dashboard.total, 2)
        XCTAssertEqual(dashboard.review, 1)
        XCTAssertGreaterThanOrEqual(dashboard.categories, 1)
    }

    func testDuplicateViewUsesOnlyExactHashCandidates() throws {
        let catalog = try TestSupport.makeCatalog()
        try seedFile(catalog, id: "file_a", path: "/tmp/dupes/a.bin")
        try seedFile(catalog, id: "file_b", path: "/tmp/dupes/b.bin")
        try seedFile(catalog, id: "file_c", path: "/tmp/dupes/unique.bin")
        try catalog.recordHash(fileID: "file_a", size: 4, sha256: Data([1, 2, 3, 4]))
        try catalog.recordHash(fileID: "file_b", size: 4, sha256: Data([1, 2, 3, 4]))
        try catalog.recordHash(fileID: "file_c", size: 4, sha256: Data([4, 3, 2, 1]))

        XCTAssertEqual(try catalog.duplicateFileIDs(), ["file_a", "file_b"])
        XCTAssertEqual(try catalog.dashboard().duplicateGroups, 1)
    }
}
