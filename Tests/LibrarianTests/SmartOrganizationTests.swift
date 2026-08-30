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
}
