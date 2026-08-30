import XCTest
@testable import LibrarianCore

final class SmartOrganizationStressTests: XCTestCase {
    func testThousandsOfNoisySignalsStillProduceSmallDiverseUsefulGroups() {
        var memberships: [(categoryPath: String, fileID: String)] = []

        // Model/evidence noise: five thousand one-off labels must never become
        // five thousand user-facing pseudo-folders.
        for index in 0..<5_000 {
            memberships.append(("Image/Raw-Model-Label-\(index)", "noise-\(index)"))
        }

        // Useful broad signals with real support.
        for course in 0..<10 {
            for item in 0..<8 {
                memberships.append(("School/COURSE-\(course)", "course-\(course)-\(item)"))
            }
        }
        for subtype in ["code", "school", "lms", "receipt", "error", "conversation", "social", "map"] {
            for item in 0..<6 {
                memberships.append(("Screenshots/\(subtype)", "shot-\(subtype)-\(item)"))
            }
        }
        for item in 0..<120 {
            memberships.append(("Projects/Code", "project-\(item)"))
        }
        for item in 0..<80 {
            memberships.append(("Documents/PDF", "pdf-\(item)"))
        }
        for item in 0..<60 {
            memberships.append(("Image/Animals", "animal-\(item)"))
        }

        var clusters: [SimilarityCluster] = []
        for index in 0..<100 {
            clusters.append(SimilarityCluster(
                id: "dup-\(index)",
                members: ["dup-\(index)-a", "dup-\(index)-b"],
                representative: "dup-\(index)-a",
                relation: .nearDuplicate,
                familyID: "dup-family-\(index)",
                confidence: 0.99,
                reason: "synthetic near duplicate"
            ))
        }
        for index in 0..<50 {
            clusters.append(SimilarityCluster(
                id: "semantic-\(index)",
                members: ["semantic-\(index)-a", "semantic-\(index)-b", "semantic-\(index)-c"],
                representative: "semantic-\(index)-a",
                relation: .semantic,
                familyID: "semantic-family-\(index)",
                confidence: 0.90,
                reason: "synthetic semantic family"
            ))
        }

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: clusters
        )

        XCTAssertLessThanOrEqual(groups.count, 18, "Smart Groups must remain a small dashboard, not a generated folder tree")
        XCTAssertTrue(groups.allSatisfy { $0.fileIDs.count >= 2 }, "singleton groups must never be promoted")
        XCTAssertFalse(groups.contains { $0.id.contains("Raw-Model-Label") }, "raw model-label noise leaked into the product surface")

        let duplicateCount = groups.filter { $0.kind == .nearDuplicate }.count
        let semanticCount = groups.filter { $0.kind == .semantic }.count
        let screenshotCount = groups.filter { $0.id.hasPrefix("category:Screenshots/") }.count
        let schoolCount = groups.filter { $0.id.hasPrefix("category:School/") }.count
        let projectCount = groups.filter { $0.id.hasPrefix("category:Projects/") }.count

        XCTAssertLessThanOrEqual(duplicateCount, 3, "duplicate families monopolized Smart Groups")
        XCTAssertLessThanOrEqual(semanticCount, 5, "semantic families monopolized Smart Groups")
        XCTAssertLessThanOrEqual(screenshotCount, 4, "screenshot subtypes monopolized Smart Groups")
        XCTAssertLessThanOrEqual(schoolCount, 4, "course groups monopolized Smart Groups")
        XCTAssertLessThanOrEqual(projectCount, 2, "project groups monopolized Smart Groups")

        XCTAssertTrue(groups.contains { $0.id == "category:Projects/Code" }, "high-support project group was crowded out")
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:School/") }, "school signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:Screenshots/") }, "screenshot signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.kind == .nearDuplicate }, "duplicate signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.kind == .semantic }, "semantic signal disappeared under noise")

        let representedLanes = Set(groups.map { group -> String in
            if group.kind == .nearDuplicate { return "duplicates" }
            if group.kind == .semantic { return "semantic" }
            if group.id.hasPrefix("category:Screenshots/") { return "screenshots" }
            if group.id.hasPrefix("category:School/") { return "school" }
            if group.id.hasPrefix("category:Projects/") { return "projects" }
            return "general"
        })
        XCTAssertGreaterThanOrEqual(representedLanes.count, 5, "Smart Groups lost useful diversity: \(representedLanes)")
    }
}
