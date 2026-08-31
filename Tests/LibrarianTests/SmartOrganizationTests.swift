import XCTest
@testable import LibrarianCore

final class SmartOrganizationTests: XCTestCase {
    func testRawVisionLabelsDoNotBecomeOneOffCategories() {
        let now = Date()
        let identity = FileIdentity(
            path: "/tmp/photo.jpg", volumeUUID: nil, fileID: 1,
            size: 1_024, mtime: now, ctime: now, kind: .image, isSymlink: false)
        var evidence = EvidenceExtractor.Evidence()
        evidence.kind = FileKind.image.rawValue
        evidence.sizeClass = "small"
        evidence.filenameTokens = ["photo"]

        let result = RuleBasedClassifier().classify(
            fileID: "file_vision",
            identity: identity,
            evidence: evidence,
            textContent: nil,
            visionLabels: [
                ("tabby cat", 0.93),
                ("one-off obscure vision label", 0.99)
            ])

        XCTAssertTrue(result.categories.contains("Image/Animals"), "got \(result.categories)")
        XCTAssertFalse(result.categories.contains("Image/tabby cat"), "raw Vision labels must not become folders")
        XCTAssertFalse(result.categories.contains(where: { $0.localizedCaseInsensitiveContains("one-off") }),
                       "unknown Vision labels must remain evidence only")
        XCTAssertTrue(result.reasonCodes.contains(where: { $0.contains("one-off-obscure-vision-label") }),
                      "raw label should remain inspectable as evidence")
    }

    func testSourceCodeGetsOneBroadProjectBucket() {
        let now = Date()
        let identity = FileIdentity(
            path: "/tmp/MyApp/main.swift", volumeUUID: nil, fileID: 2,
            size: 2_048, mtime: now, ctime: now, kind: .text, isSymlink: false)
        var evidence = EvidenceExtractor.Evidence()
        evidence.kind = FileKind.text.rawValue
        evidence.sizeClass = "small"
        evidence.filenameTokens = ["main"]

        let result = RuleBasedClassifier().classify(
            fileID: "file_project",
            identity: identity,
            evidence: evidence,
            textContent: "import Foundation\nfunc run() {}")

        XCTAssertTrue(result.categories.contains("Projects/Code"), "got \(result.categories)")
        XCTAssertFalse(result.categories.contains(where: { $0.hasPrefix("Projects/Swift/") }))
    }

    func testSmartGroupsDropSingletonTaxonomySpamAndStayBounded() {
        var memberships: [(categoryPath: String, fileID: String)] = []
        for index in 0..<80 {
            memberships.append(("Image/Random-\(index)", "single_\(index)"))
        }
        memberships += [
            ("School/MAT-171", "math_1"),
            ("School/MAT-171", "math_2"),
            ("School/MAT-171", "math_3"),
            ("Screenshots/code", "shot_1"),
            ("Screenshots/code", "shot_2"),
            ("Projects/Code", "code_1"),
            ("Projects/Code", "code_2"),
            ("Documents/PDF", "pdf_1"),
            ("Documents/PDF", "pdf_2")
        ]

        let groups = SmartOrganizationPlanner(maxGroups: 3).build(
            memberships: memberships,
            similarityClusters: [])

        XCTAssertEqual(groups.count, 3)
        XCTAssertTrue(groups.allSatisfy { $0.fileIDs.count >= 2 })
        XCTAssertTrue(groups.contains(where: { $0.title == "MAT-171" }))
        XCTAssertTrue(groups.contains(where: { $0.title == "Code screenshots" }))
        XCTAssertTrue(groups.contains(where: { $0.title == "Code projects" }))
        XCTAssertFalse(groups.contains(where: { $0.title.contains("Random") }))
    }

    func testSemanticGroupsNeedSupportAndGetHumanTitle() {
        let memberships = [
            (categoryPath: "School/CSC-151", fileID: "a"),
            (categoryPath: "School/CSC-151", fileID: "b"),
            (categoryPath: "School/CSC-151", fileID: "c")
        ]
        let strong = SimilarityCluster(
            id: "cluster-strong", members: ["a", "b", "c"], representative: "a",
            relation: .semantic, familyID: "family-strong", confidence: 0.84,
            reason: "embedding similarity")
        let weak = SimilarityCluster(
            id: "cluster-weak", members: ["x", "y", "z"], representative: "x",
            relation: .semantic, familyID: "family-weak", confidence: 0.5,
            reason: "embedding similarity")

        let groups = SmartOrganizationPlanner(maxGroups: 10).build(
            memberships: memberships,
            similarityClusters: [strong, weak])

        XCTAssertTrue(groups.contains(where: {
            $0.id == "semantic:family-strong" && $0.title == "Related CSC-151"
        }))
        XCTAssertFalse(groups.contains(where: { $0.id == "semantic:family-weak" }))
    }

    func testNoSingleSignalCanMonopolizeSmartGroups() {
        var memberships: [(categoryPath: String, fileID: String)] = [
            ("School/MAT-171", "math-1"), ("School/MAT-171", "math-2"),
            ("School/MAT-171", "math-3"),
            ("Screenshots/code", "shot-1"), ("Screenshots/code", "shot-2"),
            ("Projects/Code", "code-1"), ("Projects/Code", "code-2")
        ]
        for index in 0..<5 {
            memberships.append(("School/CSC-15\(index)", "course-\(index)-a"))
            memberships.append(("School/CSC-15\(index)", "course-\(index)-b"))
        }

        var clusters: [SimilarityCluster] = []
        for index in 0..<12 {
            clusters.append(SimilarityCluster(
                id: "dup-\(index)", members: ["dup-\(index)-a", "dup-\(index)-b"],
                representative: "dup-\(index)-a", relation: .nearDuplicate,
                familyID: "dup-family-\(index)", confidence: 0.99, reason: "near duplicate"))
        }
        for index in 0..<8 {
            clusters.append(SimilarityCluster(
                id: "sem-\(index)", members: ["sem-\(index)-a", "sem-\(index)-b", "sem-\(index)-c"],
                representative: "sem-\(index)-a", relation: .semantic,
                familyID: "sem-family-\(index)", confidence: 0.9, reason: "semantic"))
        }

        let groups = SmartOrganizationPlanner(maxGroups: 12).build(
            memberships: memberships, similarityClusters: clusters)

        XCTAssertEqual(groups.count, 12)
        XCTAssertLessThanOrEqual(groups.filter { $0.kind == .nearDuplicate }.count, 3)
        XCTAssertLessThanOrEqual(groups.filter { $0.kind == .semantic }.count, 5)
        XCTAssertTrue(groups.contains(where: { $0.title == "MAT-171" }), "better-supported course was crowded out: \(groups.map(\.title))")
        XCTAssertTrue(groups.contains(where: { $0.title == "Code screenshots" }), "screenshot group was crowded out: \(groups.map(\.title))")
        XCTAssertTrue(groups.contains(where: { $0.title == "Code projects" }), "project group was crowded out: \(groups.map(\.title))")
    }

    func testPruneRemovesLegacySingletonCategoriesButKeepsActiveHierarchy() throws {
        let catalog = try TestSupport.makeCatalog()
        let now = Date()
        let identity = FileIdentity(
            path: "/tmp/active.txt", volumeUUID: nil, fileID: 91,
            size: 10, mtime: now, ctime: now, kind: .text, isSymlink: false)
        try catalog.upsertFile(identity: identity, id: "active-file")

        let used = try catalog.ensureCategory(named: "School/MAT-171")
        _ = try catalog.ensureCategory(named: "Image/obsolete-one-off-label")
        try catalog.run(
            "INSERT INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
            binds: [.int(used), .text("active-file")])

        try catalog.pruneUnusedVirtualCategories()

        let names = try catalog.query("SELECT name FROM virtual_categories ORDER BY name") {
            $0.text(0) ?? ""
        }
        XCTAssertTrue(names.contains("School"), "active parent must remain: \(names)")
        XCTAssertTrue(names.contains("MAT-171"), "active leaf must remain: \(names)")
        XCTAssertFalse(names.contains("Image"), "unused legacy parent should be removed: \(names)")
        XCTAssertFalse(names.contains("obsolete-one-off-label"), "unused legacy leaf should be removed: \(names)")
    }

    func testReindexReplacesOldMembershipAndPrunesRetiredTaxonomy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("smart-upgrade-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("main.swift")
        try "import Foundation\nfunc run() {}\n".write(to: source, atomically: true, encoding: .utf8)

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        XCTAssertEqual(try indexer.indexRoot(root), 1)

        guard let file = try catalog.allFiles().first(where: { $0.path == source.path }) else {
            return XCTFail("indexed file missing from catalog")
        }
        let obsolete = try catalog.ensureCategory(named: "Image/obsolete-one-off-label")
        try catalog.run(
            "INSERT OR IGNORE INTO category_membership(category_id, file_id, source) VALUES(?,?,'classifier')",
            binds: [.int(obsolete), .text(file.id)])
        try catalog.run("UPDATE files SET last_extractor='legacy-taxonomy' WHERE id=?",
                        binds: [.text(file.id)])

        XCTAssertEqual(try indexer.indexRoot(root), 1, "old processing identity must force one refresh")
        let memberships = try catalog.categoryMemberships()
            .filter { $0.fileID == file.id }
            .map(\.categoryPath)
        XCTAssertTrue(memberships.contains("Projects/Code"), "new broad project bucket missing: \(memberships)")
        XCTAssertFalse(memberships.contains("Image/obsolete-one-off-label"), "old membership survived: \(memberships)")

        let names = try catalog.query("SELECT name FROM virtual_categories ORDER BY name") {
            $0.text(0) ?? ""
        }
        XCTAssertFalse(names.contains("obsolete-one-off-label"), "orphan taxonomy row survived: \(names)")
    }
}
