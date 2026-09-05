import XCTest
@testable import LibrarianCore
@testable import LibrarianAppSupport

final class SortingDecisionTests: XCTestCase {
    func testExplicitSpecialistAdjudicationReplacesConflictingExclusiveLabels() {
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
            reasonCodes: [
                "specialist:minicpm-v-4.6",
                "model:pick:Image/Scenery",
                "model:pick:Screenshots/code",
                "model:pick:School/CSC-151",
            ])

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
        XCTAssertEqual(classification.confidence, 0.84, accuracy: 0.000_001)
    }

    func testGenericSpecialistSuccessCannotEraseAnUnresolvedConflict() {
        let classification = Classification(
            fileID: "file_unresolved",
            categories: ["School/MAT-171", "School/CSC-151", "Documents/PDF"],
            description: "specialist described the file but did not choose a course",
            confidence: 0.94,
            reasonCodes: ["conflict:course", "specialist:minicpm-v-4.6", "model:useful-description"])

        XCTAssertTrue(classification.categories.contains("School/MAT-171"))
        XCTAssertTrue(classification.categories.contains("School/CSC-151"))
        XCTAssertTrue(classification.categories.contains("Review"))
        XCTAssertEqual(classification.confidence, 0.55, accuracy: 0.000_001,
                       "unresolved contradictory evidence must stay reviewable even after a high-confidence generic specialist response")
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

    func testLaneCapReassignsOverflowFilesToUsefulFallback() {
        let courses = ["MAT-171", "CSC-151", "ENG-112", "BIO-111", "PSY-150", "COM-120"]
        var memberships: [(categoryPath: String, fileID: String)] = []
        var allIDs = Set<String>()
        for course in courses {
            for index in 0..<2 {
                let id = "\(course)-\(index)"
                allIDs.insert(id)
                memberships.append(("School/\(course)", id))
                memberships.append(("Documents/PDF", id))
            }
        }

        let groups = SmartOrganizationPlanner(maxGroups: 5).build(
            memberships: memberships,
            similarityClusters: [])
        let destinations = groups.filter(\.canApplyToFinder)

        XCTAssertLessThanOrEqual(destinations.filter { $0.id.hasPrefix("category:School/") }.count, 4)
        let pdfs = destinations.first { $0.id == "category:Documents/PDF" }
        XCTAssertNotNil(pdfs,
                        "files from course destinations hidden by the lane cap must fall back to PDFs instead of disappearing")

        var counts: [String: Int] = [:]
        for group in destinations {
            for id in group.fileIDs { counts[id, default: 0] += 1 }
        }
        XCTAssertEqual(Set(counts.keys), allIDs,
                       "every file with a viable fallback should remain represented after destination caps")
        XCTAssertTrue(counts.values.allSatisfy { $0 == 1 },
                      "fallback re-election must preserve one Finder destination per file")
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
