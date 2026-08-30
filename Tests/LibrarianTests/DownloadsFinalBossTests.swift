import XCTest
@testable import LibrarianCore

final class DownloadsFinalBossTests: XCTestCase {
    func testChaoticDownloadsCollapseIntoFewUsefulHumanGroups() {
        var memberships: [(categoryPath: String, fileID: String)] = []

        func add(_ category: String, prefix: String, count: Int) {
            for index in 0..<count {
                memberships.append((category, "\(prefix)-\(index)"))
            }
        }

        // The kind of mess a real Downloads folder accumulates over months:
        // installers, app bundles, archives, generated recordings, screenshots,
        // school PDFs, code, and lots of one-off model/evidence noise.
        add("DiskImages", prefix: "dmg", count: 30)
        add("Applications", prefix: "app", count: 10)
        add("Archives", prefix: "zip", count: 20)
        add("Packages", prefix: "pkg", count: 4)
        add("Audio", prefix: "recording", count: 15)
        add("Video", prefix: "screen-recording", count: 7)
        add("Documents/PDF", prefix: "pdf", count: 25)
        add("Projects/Code", prefix: "code", count: 40)
        add("School/MAT-171", prefix: "mat", count: 12)
        add("School/CSC-151", prefix: "csc", count: 9)
        add("School/ENG-112", prefix: "eng", count: 6)
        add("Screenshots/code", prefix: "shot-code", count: 20)
        add("Screenshots/school", prefix: "shot-school", count: 18)
        add("Screenshots/receipt", prefix: "shot-receipt", count: 7)
        add("Screenshots/error", prefix: "shot-error", count: 5)

        // Repeated malformed labels must not become polished UI groups merely
        // because a buggy/imported subsystem wrote them more than once.
        add("School/Downloads", prefix: "bad-school", count: 40)
        add("Screenshots/random-junk", prefix: "bad-shot", count: 40)

        for index in 0..<2_000 {
            memberships.append(("Image/Generated-Label-\(index)", "noise-\(index)"))
        }

        var clusters: [SimilarityCluster] = []
        for index in 0..<20 {
            clusters.append(SimilarityCluster(
                id: "dup-\(index)",
                members: ["dmg-\(index)", "dmg-copy-\(index)"],
                representative: "dmg-\(index)",
                relation: .nearDuplicate,
                familyID: "download-duplicate-\(index)",
                confidence: 0.99,
                reason: "same installer downloaded again"
            ))
        }
        for index in 0..<10 {
            clusters.append(SimilarityCluster(
                id: "semantic-\(index)",
                members: ["pdf-\(index)", "mat-\(index % 12)", "shot-school-\(index)"],
                representative: "pdf-\(index)",
                relation: .semantic,
                familyID: "school-related-\(index)",
                confidence: 0.88,
                reason: "related school material"
            ))
        }

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: clusters
        )

        XCTAssertLessThanOrEqual(groups.count, 18)

        let installers = try XCTUnwrap(groups.first { $0.id == "composite:installers-archives" })
        XCTAssertEqual(installers.title, "Installers & archives")
        XCTAssertEqual(installers.fileIDs.count, 64)

        let media = try XCTUnwrap(groups.first { $0.id == "composite:media" })
        XCTAssertEqual(media.title, "Recordings & media")
        XCTAssertEqual(media.fileIDs.count, 22)

        XCTAssertTrue(groups.contains { $0.id == "category:Documents/PDF" })
        XCTAssertTrue(groups.contains { $0.id == "category:Projects/Code" })
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:School/") })
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:Screenshots/") })
        XCTAssertTrue(groups.contains { $0.kind == .nearDuplicate })

        XCTAssertEqual(groups.filter { $0.id == "composite:installers-archives" }.count, 1)
        XCTAssertEqual(groups.filter { $0.id == "composite:media" }.count, 1)
        XCTAssertLessThanOrEqual(groups.filter { $0.kind == .nearDuplicate }.count, 3)
        XCTAssertLessThanOrEqual(groups.filter { $0.id.hasPrefix("category:School/") }.count, 4)
        XCTAssertLessThanOrEqual(groups.filter { $0.id.hasPrefix("category:Screenshots/") }.count, 4)

        XCTAssertFalse(groups.contains { $0.id.contains("Generated-Label") })
        XCTAssertFalse(groups.contains { $0.id == "category:School/Downloads" })
        XCTAssertFalse(groups.contains { $0.id == "category:Screenshots/random-junk" })
    }
}
