import XCTest
@testable import LibrarianCore
@testable import LibrarianAppSupport

final class SortingDecisionTests: XCTestCase {
    func testSpecialistAdjudicationReplacesConflictingExclusiveLabels() {
        let classification = Classification(
            fileID: "file_specialist",
            categories: [
                "Image",
                "Image/Animals",
                "Image/Scenery",
                "Screenshots/school",
                "Screenshots/code",
                "School/MAT-171",
                "School/CSC-151",
                "Documents/PDF",
            ],
            description: "",
            confidence: 0.84,
            reasonCodes: ["specialist:minicpm-v-4.6"])

        XCTAssertEqual(classification.categories, [
            "Image",
            "Image/Scenery",
            "Screenshots/code",
            "School/CSC-151",
            "Documents/PDF",
        ])
        XCTAssertFalse(classification.categories.contains("Image/Animals"))
        XCTAssertFalse(classification.categories.contains("Screenshots/school"))
        XCTAssertFalse(classification.categories.contains("School/MAT-171"))
    }

    func testDeterministicEvidenceStaysMultiLabelUntilAnAdjudicatorRuns() {
        let classification = Classification(
            fileID: "file_evidence",
            categories: ["School/MAT-171", "School/CSC-151", "Documents/PDF"],
            description: "",
            confidence: 0.55,
            reasonCodes: ["text:CSC-151", "filename:MAT-171"])

        XCTAssertEqual(classification.categories,
                       ["School/MAT-171", "School/CSC-151", "Documents/PDF"])
    }

    func testConflictingCourseEvidenceIsNotPretendedToBeConfident() {
        let now = Date()
        let identity = FileIdentity(
            path: "/tmp/MAT-171 review.txt", volumeUUID: nil, fileID: 42,
            size: 128, mtime: now, ctime: now, kind: .text, isSymlink: false)
        var evidence = EvidenceExtractor.Evidence()
        evidence.kind = FileKind.text.rawValue
        evidence.sizeClass = "small"
        evidence.filenameTokens = ["mat", "171", "review"]

        let result = RuleBasedClassifier().classify(
            fileID: "file_conflict",
            identity: identity,
            evidence: evidence,
            textContent: "CSC-151 assignment about Java classes and methods")

        XCTAssertTrue(result.categories.contains("School/MAT-171"), "got \(result.categories)")
        XCTAssertTrue(result.categories.contains("School/CSC-151"), "got \(result.categories)")
        XCTAssertTrue(result.categories.contains("Review"), "conflict must enter Review")
        XCTAssertTrue(result.reasonCodes.contains("conflict:course"))
        XCTAssertEqual(result.confidence, 0.55, accuracy: 0.000_001)
    }

    func testPerFilePreferenceBeatsGlobalAlphabeticalTie() {
        let memberships = [
            (categoryPath: "School/MAT-171", fileID: "a"),
            (categoryPath: "School/CSC-151", fileID: "a"),
            (categoryPath: "School/MAT-171", fileID: "b"),
            (categoryPath: "School/CSC-151", fileID: "b"),
            (categoryPath: "Documents/PDF", fileID: "a"),
            (categoryPath: "Documents/PDF", fileID: "b"),
        ]

        let groups = SmartOrganizationPlanner(maxGroups: 8).build(
            memberships: memberships,
            similarityClusters: [],
            preferredCategoryByFile: ["a": "School/MAT-171", "b": "School/MAT-171"])

        XCTAssertEqual(Set(groups.first { $0.title == "MAT-171" }?.fileIDs ?? []), ["a", "b"])
        XCTAssertFalse(groups.contains { $0.title == "CSC-151" })
        XCTAssertFalse(groups.contains { $0.title == "PDFs" })
    }

    func testRelationshipGroupsCannotRepresentFinderDestinations() {
        let relation = SmartOrganizationGroup(
            id: "semantic:test",
            title: "Related items",
            subtitle: "relationship only",
            kind: .semantic,
            fileIDs: ["a", "b", "c"],
            confidence: 0.9)
        let duplicate = SmartOrganizationGroup(
            id: "duplicate:test",
            title: "Near-duplicate family",
            subtitle: "relationship only",
            kind: .nearDuplicate,
            fileIDs: ["a", "b"],
            confidence: 0.99)

        XCTAssertFalse(relation.canApplyToFinder)
        XCTAssertFalse(duplicate.canApplyToFinder)

        XCTAssertThrowsError(try OrganizationApplier.plan(
            group: relation,
            pathFor: { _ in "/tmp/example.txt" },
            sourceRoots: ["/tmp"])) { error in
                XCTAssertEqual(error as? OrganizationApplier.ApplyError, .relationshipOnly)
            }
    }
}
