import XCTest
@testable import LibrarianCore
@testable import LibrarianAppSupport

/// Regressions for the app-level "works as intended" fixes:
/// multi-word exact search, and the journaled Apply-to-Finder plan/apply/undo.
final class ApplyAndSearchRegressionTests: XCTestCase {

    // MARK: - FTS query building

    func testFTSMatchQuerySplitsTermsIntoQuotedANDQuery() {
        XCTAssertEqual(Catalog.ftsMatchQuery("invoice pdf"), "\"invoice\" \"pdf\"")
        XCTAssertEqual(Catalog.ftsMatchQuery("  spaced   out  "), "\"spaced\" \"out\"")
        XCTAssertEqual(Catalog.ftsMatchQuery("\"exact phrase\""), "\"exact phrase\"")
        XCTAssertEqual(Catalog.ftsMatchQuery(""), "")
        XCTAssertEqual(Catalog.ftsMatchQuery("   "), "")
    }

    func testFTSMatchQueryIsInjectionSafe() {
        // Crafted input must end up as inert quoted terms: every non-space
        // character of the built MATCH query lives inside double quotes, so
        // FTS5 treats it as literal text (phrases cannot execute operators).
        func allContentQuoted(_ built: String) -> Bool {
            var insideQuotes = false
            for character in built {
                if character == "\"" {
                    insideQuotes.toggle()
                    continue
                }
                if !insideQuotes && !character.isWhitespace { return false }
            }
            return !insideQuotes
        }

        for malicious in ["\" OR 1=1 --", "x\" OR status='indexed' --", "NEAR(a b) OR", "NOT", "*"] {
            let built = Catalog.ftsMatchQuery(malicious)
            XCTAssertTrue(allContentQuoted(built), "unquoted content survived for \(malicious): \(built)")
        }
        XCTAssertEqual(Catalog.ftsMatchQuery("\" OR 1=1 --"), "\"OR 1=1 --\"")
    }

    func testSearchExactMultiWordANDSemantics() throws {
        let catalog = try TestSupport.makeCatalog()

        func indexTextFile(id: String, path: String, body: String) throws {
            try catalog.upsertFile(
                identity: FileIdentity(path: path, volumeUUID: nil, fileID: UInt64(abs(id.hashValue % 1000)) + 1,
                                       size: Int64(body.utf8.count),
                                       mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                       ctime: Date(timeIntervalSince1970: 1_700_000_000),
                                       kind: .text, isSymlink: false),
                id: id)
            try catalog.setStatus(fileID: id, status: "indexed")
            try catalog.saveText(fileID: id, body: body, extractor: "test")
        }

        // "alpha" and "bravo" appear in one document but never adjacent.
        try indexTextFile(id: "far-apart", path: "/tmp/far_apart.txt", body: """
        alpha appears here at the beginning.
        This middle line is filler so the next word is far away.
        The document ends with bravo right here.
        """)
        // "gamma delta" is an adjacent phrase; neither word appears alone elsewhere.
        try indexTextFile(id: "phrase-only", path: "/tmp/phrase_only.txt", body: """
        gamma delta is an adjacent phrase, but neither word
        appears anywhere else in this document alone.
        """)

        // The regression: "alpha bravo" used to be forced into the phrase
        // query "alpha bravo", which matched nothing. AND semantics match.
        let andHits = try catalog.searchExact("alpha bravo")
        XCTAssertTrue(andHits.contains { $0.fileID == "far-apart" },
                      "multi-word AND search must match non-adjacent words")

        // Words that do not co-occur in one document must not match that document.
        let disjoint = try catalog.searchExact("alpha delta")
        XCTAssertFalse(disjoint.contains { $0.fileID == "phrase-only" })
        XCTAssertFalse(disjoint.contains { $0.fileID == "far-apart" },
                       "delta does not appear in far_apart.txt")

        // Adjacent phrases keep working.
        let phrase = try catalog.searchExact("gamma delta")
        XCTAssertTrue(phrase.contains { $0.fileID == "phrase-only" })
    }

    // MARK: - Apply journal

    func testApplyJournalRoundtrip() throws {
        let catalog = try TestSupport.makeCatalog()
        let entries = [
            Catalog.ApplyJournalEntry(fileID: "f1", fromPath: "/tmp/a.pdf", toPath: "/tmp/Sorted/a.pdf"),
            Catalog.ApplyJournalEntry(fileID: "f2", fromPath: "/tmp/b.pdf", toPath: "/tmp/Sorted/b.pdf"),
        ]
        try catalog.recordApplyBatch(batchID: "batch-1", appliedAt: 100, entries: entries)
        try catalog.recordApplyBatch(batchID: "batch-2", appliedAt: 200,
                                     entries: [Catalog.ApplyJournalEntry(fileID: "f3",
                                                                         fromPath: "/c", toPath: "/Sorted/c")])

        XCTAssertEqual(try catalog.latestApplyBatchID(), "batch-2")
        XCTAssertEqual(try catalog.applyBatchEntries(batchID: "batch-1"), entries)

        try catalog.deleteApplyBatch(batchID: "batch-2")
        XCTAssertEqual(try catalog.latestApplyBatchID(), "batch-1")
    }

    func testUpdateAppliedPathIsGuardedByOriginalPath() throws {
        let catalog = try TestSupport.makeCatalog()
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)
        let file = try catalog.allFiles().first { $0.path.hasSuffix("csc151-ch4.txt") }!

        let moved = file.path + ".moved"
        try catalog.updateAppliedPath(fileID: file.id, fromPath: file.path, toPath: moved)
        XCTAssertEqual(try catalog.fileRow(id: file.id)?.path, moved)

        // A stale plan (old fromPath) must not rewrite the row again.
        try catalog.updateAppliedPath(fileID: file.id, fromPath: file.path, toPath: "/somewhere/else")
        XCTAssertEqual(try catalog.fileRow(id: file.id)?.path, moved)
    }

    // MARK: - OrganizationApplier

    private struct StaticLease: OrganizationLease {
        let url: URL

        func targetURL(for requestedPath: String, originalRootPath: String) -> URL? {
            let root = originalRootPath.hasSuffix("/")
                ? String(originalRootPath.dropLast()) : originalRootPath
            guard requestedPath == root || SourceBroker.isPath(requestedPath, under: root) else { return nil }
            if requestedPath == root { return url }
            let prefix = root + "/"
            guard requestedPath.hasPrefix(prefix) else { return nil }
            return url.appendingPathComponent(String(requestedPath.dropFirst(prefix.count)))
        }
    }

    private func makeTempTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("librarian-apply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try "one".write(to: root.appendingPathComponent("report_a.pdf"), atomically: true, encoding: .utf8)
        try "two".write(to: root.appendingPathComponent("report_b.pdf"), atomically: true, encoding: .utf8)
        try "three".write(to: root.appendingPathComponent("sub/report_c.pdf"), atomically: true, encoding: .utf8)
        try "gone".write(to: root.appendingPathComponent("report_missing.pdf"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("report_missing.pdf"))
        return root
    }

    private func group(_ title: String, paths: [String]) -> SmartOrganizationGroup {
        SmartOrganizationGroup(id: "category:Test", title: title, subtitle: "",
                               kind: .category, fileIDs: paths)
    }

    func testPlanPicksMajorityRootAndReportsGaps() throws {
        let rootA = try makeTempTree()
        let rootB = try makeTempTree()
        defer {
            try? FileManager.default.removeItem(at: rootA.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: rootB.deletingLastPathComponent())
        }

        let plan = try OrganizationApplier.plan(
            group: group("PDFs", paths: [
                rootA.appendingPathComponent("report_a.pdf").path,
                rootA.appendingPathComponent("report_b.pdf").path,
                rootA.appendingPathComponent("report_missing.pdf").path,
                rootB.appendingPathComponent("report_a.pdf").path,
            ]),
            pathFor: { $0 },
            sourceRoots: [rootA.path, rootB.path])

        XCTAssertEqual(plan.destinationRootPath, rootA.path)
        XCTAssertEqual(plan.items.count, 2)
        XCTAssertEqual(plan.missingPaths.count, 1)
        XCTAssertEqual(plan.skippedOtherRoots, 1)
        XCTAssertEqual(plan.destinationFolderPath, rootA.path + "/PDFs")
    }

    func testPlanSanitizesFolderName() {
        XCTAssertEqual(OrganizationApplier.sanitizedFolderName(from: "Code projects"), "Code projects")
        XCTAssertFalse(OrganizationApplier.sanitizedFolderName(from: "a/b:c").contains("/"))
        XCTAssertFalse(OrganizationApplier.sanitizedFolderName(from: "a/b:c").contains(":"))
        XCTAssertEqual(OrganizationApplier.sanitizedFolderName(from: "   "), "Organized files")
    }

    func testApplyMovesFilesJournalsAndUpdatesCatalogThenUndoRestores() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let catalog = try TestSupport.makeCatalog()

        let originalA = root.appendingPathComponent("report_a.pdf")
        let originalC = root.appendingPathComponent("sub/report_c.pdf")
        let plan = try OrganizationApplier.plan(
            group: group("PDFs", paths: [originalA.path, originalC.path]),
            pathFor: { $0 },
            sourceRoots: [root.path])

        let outcome = try OrganizationApplier.apply(
            plan: plan,
            leaseForRoot: { _ in StaticLease(url: root) },
            catalog: catalog)

        XCTAssertEqual(outcome.moved, 2, "both files must move")
        XCTAssertTrue(outcome.succeeded)

        let destination = root.appendingPathComponent("PDFs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report_a.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report_c.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalA.path))

        // Journal recorded exactly what moved.
        let batchID = try catalog.latestApplyBatchID()
        XCTAssertEqual(batchID, plan.id)
        let entries = try catalog.applyBatchEntries(batchID: plan.id)
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.contains { $0.fromPath == originalA.path })

        // Undo restores every file to its original location.
        let undo = OrganizationApplier.undoLatest(
            catalog: catalog,
            sourceRoots: [root.path],
            leaseForRoot: { _ in StaticLease(url: root) })
        XCTAssertEqual(undo?.restored, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalA.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalC.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report_a.pdf").path))

        // A fully restored batch leaves no dangling journal rows.
        XCTAssertNil(try catalog.latestApplyBatchID())
    }

    func testApplyConflictAvoidanceDoesNotOverwrite() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let catalog = try TestSupport.makeCatalog()
        let destination = root.appendingPathComponent("PDFs")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "existing".write(to: destination.appendingPathComponent("report_a.pdf"),
                             atomically: true, encoding: .utf8)

        let original = root.appendingPathComponent("report_a.pdf")
        let plan = try OrganizationApplier.plan(
            group: group("PDFs", paths: [original.path]),
            pathFor: { $0 },
            sourceRoots: [root.path])
        let outcome = try OrganizationApplier.apply(
            plan: plan,
            leaseForRoot: { _ in StaticLease(url: root) },
            catalog: catalog)

        XCTAssertEqual(outcome.moved, 1)
        // The pre-existing file is intact and the moved file got a new name.
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report_a.pdf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("report_a 2.pdf").path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("report_a.pdf"), encoding: .utf8), "existing")
    }

    func testPlanWithoutMovableMembersFailsClosed() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        XCTAssertThrowsError(try OrganizationApplier.plan(
            group: group("Empty", paths: []), pathFor: { _ in "" }, sourceRoots: [root.path]))
        // Member outside every authorized root cannot be planned.
        XCTAssertThrowsError(try OrganizationApplier.plan(
            group: group("Outside", paths: ["/definitely/not/authorized/x.pdf"]),
            pathFor: { $0 },
            sourceRoots: [root.path]))
    }
}
