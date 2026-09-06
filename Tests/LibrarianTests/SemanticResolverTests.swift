import XCTest
@testable import LibrarianCore

final class SemanticResolverTests: XCTestCase {
    func testExtractedContentBeatsMisleadingFilenameCourse() {
        let base = Classification(
            fileID: "file_contentwins",
            categories: ["Documents/PDF", "School/MAT-171", "School/BIO-111", "Review"],
            description: "pdf",
            confidence: 0.55,
            reasonCodes: ["kind:pdf", "text:MAT-171", "filename:BIO-111", "conflict:course"])

        let resolved = SemanticResolver().resolve(base: base)
        XCTAssertTrue(resolved.categories.contains("School/MAT-171"))
        XCTAssertFalse(resolved.categories.contains("School/BIO-111"))
        XCTAssertFalse(resolved.categories.contains("Review"))
        XCTAssertGreaterThanOrEqual(resolved.confidence, 0.86)
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:content-over-filename"))
    }

    func testGenericPDFStaysAmbiguousForSpecialistJudge() {
        let base = Classification(
            fileID: "file_genericpdf",
            categories: ["Documents/PDF"],
            description: "pdf",
            confidence: 0.91,
            reasonCodes: ["kind:pdf"])

        let resolved = SemanticResolver().resolve(base: base)
        XCTAssertEqual(resolved.confidence, 0.69, accuracy: 0.0001)
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:needs-judge"))
        XCTAssertLessThan(resolved.confidence, SemanticResolver.specialistEscalationThreshold)
    }

    func testSiblingConsensusCanResolveVagueFileButOneSiblingCannot() {
        let base = Classification(
            fileID: "file_vague",
            categories: ["Documents/PDF"],
            description: "pdf",
            confidence: 0.55,
            reasonCodes: ["kind:pdf"])

        let weak = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/BIO-111", confidence: 0.99,
                                     source: .sibling)
        ])
        let unresolved = SemanticResolver().resolve(base: base, context: weak)
        XCTAssertFalse(unresolved.categories.contains("School/BIO-111"))
        XCTAssertEqual(unresolved.confidence, 0.55, accuracy: 0.0001)

        let consensus = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/BIO-111", confidence: 1.0,
                                     supportCount: 4, source: .sibling)
        ])
        let resolved = SemanticResolver().resolve(base: base, context: consensus)
        XCTAssertTrue(resolved.categories.contains("School/BIO-111"))
        XCTAssertGreaterThanOrEqual(resolved.confidence, 0.80)
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:sibling-consensus"))
    }

    func testOpaqueArchiveCannotBecomeCodeProjectFromFolderConsensus() {
        let base = Classification(
            fileID: "file_archive",
            categories: ["Archives"],
            description: "archive",
            confidence: 0.55,
            reasonCodes: ["kind:archive"])
        let context = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "Projects/Code", confidence: 0.99,
                                     supportCount: 8, source: .sibling)
        ])

        let resolved = SemanticResolver().resolve(base: base, context: context)
        XCTAssertEqual(resolved.categories, ["Archives"])
        XCTAssertFalse(resolved.reasonCodes.contains("semantic:sibling-consensus"))
        XCTAssertEqual(resolved.confidence, 0.55, accuracy: 0.0001)
    }

    func testAmbientContextCannotOverrideStrongExtractedCourseEvidence() {
        let base = Classification(
            fileID: "file_mat",
            categories: ["Documents/Text", "School/MAT-171"],
            description: "text",
            confidence: 0.82,
            reasonCodes: ["kind:text", "text:MAT-171"])
        let context = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/CSC-151", confidence: 1.0,
                                     supportCount: 8, source: .sibling)
        ])

        let resolved = SemanticResolver().resolve(base: base, context: context)
        XCTAssertTrue(resolved.categories.contains("School/MAT-171"))
        XCTAssertFalse(resolved.categories.contains("School/CSC-151"))
        XCTAssertFalse(resolved.reasonCodes.contains("semantic:sibling-consensus"))
    }

    func testSemanticClusterRequiresCorroboration() {
        let base = Classification(
            fileID: "file_clustered",
            categories: ["Image"],
            description: "image",
            confidence: 0.55,
            reasonCodes: ["kind:image"])
        let context = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/CSC-151", confidence: 0.96,
                                     supportCount: 2, source: .similarityCluster)
        ])

        let resolved = SemanticResolver().resolve(base: base, context: context)
        XCTAssertTrue(resolved.categories.contains("School/CSC-151"))
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:cluster-consensus"))
        XCTAssertGreaterThan(resolved.confidence, SemanticResolver.specialistEscalationThreshold)
    }

    func testNearlyTiedConflictingContextDoesNotGuess() {
        let base = Classification(
            fileID: "file_conflict",
            categories: ["Documents/PDF"],
            description: "pdf",
            confidence: 0.55,
            reasonCodes: ["kind:pdf"])
        let context = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/BIO-111", confidence: 1.0,
                                     supportCount: 4, source: .sibling),
            SemanticContextCandidate(category: "School/MAT-171", confidence: 0.98,
                                     supportCount: 4, source: .sibling)
        ])

        let resolved = SemanticResolver().resolve(base: base, context: context)
        XCTAssertFalse(resolved.categories.contains("School/BIO-111"))
        XCTAssertFalse(resolved.categories.contains("School/MAT-171"))
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:needs-judge"))
    }

    func testValidatedModelJudgeCanSetOneBoundedDestination() {
        let base = Classification(
            fileID: "file_modeljudge",
            categories: ["Image", "Image/Documents", "Review"],
            description: "image",
            confidence: 0.55,
            reasonCodes: ["kind:image"])
        let context = SemanticResolutionContext(candidates: [
            SemanticContextCandidate(category: "School/ENG-112", confidence: 0.94,
                                     source: .modelJudge)
        ])

        let resolved = SemanticResolver().resolve(base: base, context: context)
        XCTAssertTrue(resolved.categories.contains("School/ENG-112"))
        XCTAssertFalse(resolved.categories.contains("Review"))
        XCTAssertTrue(resolved.reasonCodes.contains("specialist:semantic-judge"))
        XCTAssertTrue(resolved.reasonCodes.contains("model:pick:School/ENG-112"))
    }
}
