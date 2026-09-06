import XCTest
@testable import LibrarianCore

final class SemanticContextIntegrationTests: XCTestCase {
    private func seedFile(_ catalog: Catalog, id: String, path: String, kind: String = "pdf") throws {
        try catalog.run("""
            INSERT INTO files(id, path, volume_uuid, fs_file_id, size, mtime, ctime, kind, status, first_seen, last_extractor)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, binds: [
                .text(id), .text(path), .text("volume"), .int(Int64(id.hashValue)),
                .int(256), .real(100), .real(100), .text(kind), .text("indexed"),
                .real(100), .text("semantic-test-v1"),
            ])
    }

    private func save(_ catalog: Catalog, id: String, categories: [String],
                      confidence: Double, reasons: [String]) throws {
        try catalog.saveClassification(
            Classification(fileID: id,
                           categories: categories,
                           description: "semantic integration fixture",
                           confidence: confidence,
                           reasonCodes: reasons),
            classifier: "semantic-test")
    }

    func testVaguePDFInheritsCorroboratedSiblingCourseInRealFinderPlanningView() throws {
        let catalog = try TestSupport.makeCatalog()
        for index in 1...4 {
            let id = "bio_peer_\(index)"
            try seedFile(catalog, id: id, path: "/scope/bio-peer-\(index).pdf")
            try save(catalog, id: id,
                     categories: ["Documents/PDF", "School/BIO-111"],
                     confidence: 0.94,
                     reasons: ["kind:pdf", "text:BIO-111"])
        }
        try seedFile(catalog, id: "mystery", path: "/scope/document (17).pdf")
        try save(catalog, id: "mystery",
                 categories: ["Documents/PDF"], confidence: 0.55,
                 reasons: ["kind:pdf", "semantic:needs-judge"])

        let resolved = try XCTUnwrap(
            catalog.semanticallyResolvedClassification(fileID: "mystery", roots: ["/scope"]))
        XCTAssertTrue(resolved.categories.contains("School/BIO-111"))
        XCTAssertGreaterThanOrEqual(resolved.confidence, 0.80)
        XCTAssertTrue(resolved.reasonCodes.contains("semantic:sibling-consensus"))

        let memberships = try catalog.semanticOrganizationMemberships(roots: ["/scope"])
        XCTAssertTrue(memberships.contains {
            $0.fileID == "mystery" && $0.categoryPath == "School/BIO-111"
        })

        let groups = try catalog.smartOrganizationGroups(roots: ["/scope"])
        let bio = try XCTUnwrap(groups.first { $0.id == "category:School/BIO-111" })
        XCTAssertTrue(bio.fileIDs.contains("mystery"))
        XCTAssertTrue(bio.canApplyToFinder)
    }

    func testSelectedRootCannotBorrowSemanticVotesFromAnotherRoot() throws {
        let catalog = try TestSupport.makeCatalog()

        try seedFile(catalog, id: "target", path: "/scope/document.pdf")
        try save(catalog, id: "target",
                 categories: ["Documents/PDF"], confidence: 0.55,
                 reasons: ["kind:pdf", "semantic:needs-judge"])

        // One local peer is enough to establish the scoped taxonomy but is
        // deliberately below the resolver's 3-sibling consensus requirement.
        try seedFile(catalog, id: "local_bio", path: "/scope/known.pdf")
        try save(catalog, id: "local_bio",
                 categories: ["Documents/PDF", "School/BIO-111"], confidence: 0.95,
                 reasons: ["kind:pdf", "text:BIO-111"])

        for index in 1...3 {
            let id = "external_bio_\(index)"
            try seedFile(catalog, id: id, path: "/other/bio-\(index).pdf")
            try save(catalog, id: id,
                     categories: ["Documents/PDF", "School/BIO-111"], confidence: 0.96,
                     reasons: ["kind:pdf", "text:BIO-111"])
        }

        try catalog.run("""
            INSERT INTO similarity_clusters(id, family_id, relation, representative, confidence, reason, updated)
            VALUES(?,?,?,?,?,?,?)
            """, binds: [
                .text("cross-root"), .text("cross-root"), .text("semantic"), .text("target"),
                .real(0.96), .text("test"), .real(100),
            ])
        for id in ["target", "external_bio_1", "external_bio_2", "external_bio_3"] {
            try catalog.run("INSERT INTO similarity_cluster_members(cluster_id,file_id) VALUES(?,?)",
                            binds: [.text("cross-root"), .text(id)])
        }

        // Global context proves the external semantic evidence is strong enough
        // to resolve the target when no root boundary is requested.
        let global = try XCTUnwrap(catalog.semanticallyResolvedClassification(fileID: "target"))
        XCTAssertTrue(global.categories.contains("School/BIO-111"))
        XCTAssertTrue(global.reasonCodes.contains("semantic:cluster-consensus"))

        // The exact same target under a scoped organization request must not
        // consume peers from /other.
        let scoped = try XCTUnwrap(
            catalog.semanticallyResolvedClassification(fileID: "target", roots: ["/scope"]))
        XCTAssertFalse(scoped.categories.contains("School/BIO-111"))
        XCTAssertLessThan(scoped.confidence, 0.80)

        let memberships = try catalog.semanticOrganizationMemberships(roots: ["/scope"])
        XCTAssertFalse(memberships.contains {
            $0.fileID == "target" && $0.categoryPath == "School/BIO-111"
        })
    }
}
