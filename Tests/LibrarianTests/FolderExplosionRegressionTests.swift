import XCTest
@testable import LibrarianCore

final class FolderExplosionRegressionTests: XCTestCase {
    func testThreeHundredSupportedLookingSchoolBucketsStayBounded() {
        var memberships: [(categoryPath: String, fileID: String)] = []

        // These are deliberately not nonsense labels. Every category is syntactically
        // valid and has enough support to qualify, so the lane cap — not garbage
        // rejection — must prevent a 300-folder-style product surface.
        for index in 0..<300 {
            let course = "MAT-\(100 + index)"
            memberships.append(("School/\(course)", "\(course)-a"))
            memberships.append(("School/\(course)", "\(course)-b"))
        }

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: []
        )

        XCTAssertLessThanOrEqual(groups.count, 18)
        XCTAssertLessThanOrEqual(
            groups.filter { $0.id.hasPrefix("category:School/") }.count,
            4,
            "300 plausible supported buckets must not become a wall of virtual folders"
        )
        XCTAssertTrue(groups.allSatisfy { $0.fileIDs.count >= 2 })
    }

    func testThreeHundredDuplicateFamiliesCannotMonopolizeSmartGroups() {
        var clusters: [SimilarityCluster] = []
        for index in 0..<300 {
            clusters.append(SimilarityCluster(
                id: "dup-\(index)",
                members: ["dup-\(index)-a", "dup-\(index)-b"],
                representative: "dup-\(index)-a",
                relation: .nearDuplicate,
                familyID: "family-\(index)",
                confidence: 0.99,
                reason: "synthetic duplicate flood"
            ))
        }

        let memberships: [(categoryPath: String, fileID: String)] = [
            ("Projects/Code", "project-a"),
            ("Projects/Code", "project-b"),
            ("Screenshots/code", "shot-a"),
            ("Screenshots/code", "shot-b"),
            ("Documents/PDF", "pdf-a"),
            ("Documents/PDF", "pdf-b")
        ]

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: clusters
        )

        XCTAssertLessThanOrEqual(groups.count, 18)
        XCTAssertLessThanOrEqual(
            groups.filter { $0.kind == .nearDuplicate }.count,
            3,
            "duplicate floods must not crowd every other useful group off the screen"
        )
        XCTAssertTrue(groups.contains { $0.id == "category:Projects/Code" })
        XCTAssertTrue(groups.contains { $0.id == "category:Screenshots/code" })
        XCTAssertTrue(groups.contains { $0.id == "category:Documents/PDF" })
    }

    func testThreeHundredRepeatedVagueLabelsProduceNoGroups() {
        var memberships: [(categoryPath: String, fileID: String)] = []
        for index in 0..<300 {
            for item in 0..<5 {
                memberships.append(("Stuff/Topic-\(index)", "vague-\(index)-\(item)"))
            }
        }

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: []
        )

        XCTAssertTrue(groups.isEmpty, "repetition alone must never legitimize arbitrary model-created taxonomy")
    }
}
