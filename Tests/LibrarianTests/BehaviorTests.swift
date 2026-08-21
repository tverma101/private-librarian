import XCTest
@testable import LibrarianCore

/// Duplicate detection (§18/§19), incremental indexing (§33),
/// virtual organization (§25), search (§29), scheduler (§30).
final class BehaviorTests: XCTestCase {

    func testExactDuplicatesReportedNotDeleted() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        let groups = try indexer.computeDuplicateGroups()
        XCTAssertEqual(groups.count, 1, "expected exactly one duplicate group, got \(groups)")
        guard let first = groups.first else {
            return XCTFail("no duplicate groups returned")
        }
        let group = Set(first)

        let files = try catalog.allFiles()
        let a = files.first { $0.path.hasSuffix("dup_a.bin") }!.id
        let b = files.first { $0.path.hasSuffix("dup_b.bin") }!.id
        XCTAssertEqual(group, [a, b], "near_dup.bin must NOT be in the exact-duplicate group")

        // Report-only: both files still exist on disk.
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Images/dup_a.bin").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Images/dup_b.bin").path))
    }

    func testIncrementalIndexingSkipsUnchangedFiles() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        // Touch nothing → second pass should not reprocess (status stays indexed,
        // and mtimes of sources stay identical — covered by immutability tests).
        let counts1 = try catalog.counts()
        _ = try indexer.indexRoot(root)
        let counts2 = try catalog.counts()
        XCTAssertEqual(counts1["indexed"], counts2["indexed"])

        // Modify one file → it gets reprocessed; others untouched.
        // Path spelling: the catalog stores enumerator-emitted paths, so
        // look records up by unique suffix rather than exact string.
        let target = root.appendingPathComponent("School/csc151-ch4.txt")
        let oldRecord = try catalog.allFiles().first { $0.path.hasSuffix("School/csc151-ch4.txt") }
        XCTAssertNotNil(oldRecord, "file must be in catalog before modification")
        let oldSize = oldRecord!.size
        Thread.sleep(forTimeInterval: 0.05)
        try "CSC-151 Chapter 5 notes. Updated content with MAT-171 mention."
            .write(to: target, atomically: true, encoding: .utf8)
        _ = try indexer.indexRoot(root)

        let updated = try catalog.allFiles().first { $0.path.hasSuffix("School/csc151-ch4.txt") }
        XCTAssertNotNil(updated)
        XCTAssertGreaterThan(updated!.size, 60, "updated content must be re-indexed (new size)")
        XCTAssertNotEqual(updated!.size, oldSize, "modified file must be re-stat'd and updated")
    }

    func testVirtualTreeAndMultiLabelMembership() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        // The course text file should carry multiple labels: Documents/Text + School/CSC-151 + Assignment.
        let files = try catalog.allFiles()
        let txt = files.first { $0.path.hasSuffix("csc151-ch4.txt") }!
        // Reconstruct full hierarchical paths: walk UP from each membership
        // to its root; the root-level row is the complete path. Structural,
        // not lexicographic (a MAX(path) hack reports the wrong spelling).
        let sql = """
            WITH RECURSIVE up(member, id, path) AS (
                SELECT m.category_id, c.id, c.name
                FROM category_membership m JOIN virtual_categories c ON c.id = m.category_id
                WHERE m.file_id=?
                UNION ALL
                SELECT up.member, p.id, p.name || '/' || up.path
                FROM up JOIN virtual_categories p ON p.id = (
                    SELECT parent_id FROM virtual_categories WHERE id = up.id)
            )
            SELECT u.path FROM up u JOIN virtual_categories r ON r.id = u.id
            WHERE r.parent_id IS NULL
            """
        let cats = try catalog.query(sql, binds: [.text(txt.id)]) { $0.text(0) ?? "" }
        XCTAssertTrue(cats.contains("Documents/Text"), "got \(cats)")
        XCTAssertTrue(cats.contains("School/CSC-151"), "got \(cats)")
        XCTAssertTrue(cats.contains("Assignment"), "got \(cats)")

        // No real directories were created for categories.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("School/CSC-151").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Documents").path))
    }

    func testFTS5SearchFindsContent() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        let hits = try catalog.searchExact("inheritance")
        XCTAssertTrue(hits.contains { $0.path.hasSuffix("csc151-ch4.txt") })

        // Quote-escape safety: user input can't break FTS syntax.
        let weird = try catalog.searchExact("\" OR 1=1 --")
        _ = weird // must not throw
    }

    func testSchedulerConcurrencyCaps() async throws {
        let s = Scheduler()
        let tracker = PeakTracker()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    let now = try await s.performAsync(as: .heavy) {
                        tracker.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        tracker.exit()
                        return ()
                    }
                    _ = now
                }
            }
            try await group.waitForAll()
        }
        XCTAssertLessThanOrEqual(tracker.peak(), 1)
    }

    func testConfidenceBands() {
        XCTAssertEqual(ReviewState.from(confidence: 0.9), .confident)
        XCTAssertEqual(ReviewState.from(confidence: 0.6), .ambiguous)
        XCTAssertEqual(ReviewState.from(confidence: 0.2), .needsReview)
    }
}
