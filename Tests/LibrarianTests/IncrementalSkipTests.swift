import XCTest
@testable import LibrarianCore

/// Regression tests for the real incremental gate. The old test only compared
/// catalog row counts, which remained equal even when every file was re-run.
final class IncrementalSkipTests: XCTestCase {

    func testUnchangedSecondPassProcessesZeroEntries() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())

        let first = try indexer.indexRoot(root)
        XCTAssertGreaterThan(first, 0, "first scan must actually process fixture entries")

        indexer.resetWorkMetrics()
        let second = try indexer.indexRoot(root)
        XCTAssertEqual(second, 0,
                       "unchanged second scan must skip before extraction/Vision/Tier-2 work")
        XCTAssertEqual(indexer.workMetrics, Indexer.WorkMetrics(),
                       "unchanged scan must make zero expensive extractor/provider calls")
    }

    func testExactlyOneModifiedFileIsReprocessed() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())

        _ = try indexer.indexRoot(root)
        XCTAssertEqual(try indexer.indexRoot(root), 0)

        let target = root.appendingPathComponent("School/csc151-ch4.txt")
        Thread.sleep(forTimeInterval: 0.02)
        try "CSC-151 Chapter 5 notes. Updated content deliberately changes both size and mtime."
            .write(to: target, atomically: true, encoding: .utf8)

        let third = try indexer.indexRoot(root)
        XCTAssertEqual(third, 1,
                       "changing one source must reprocess exactly that source, not the whole library")

        XCTAssertEqual(try indexer.indexRoot(root), 0,
                       "after the changed generation is indexed, the next pass must be idle again")
    }

    func testPendingStateNeverQualifiesForSkip() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        let targetPath = root.appendingPathComponent("School/csc151-ch4.txt").path
        guard let row = try catalog.allFiles().first(where: { $0.path == targetPath || $0.path.hasSuffix("School/csc151-ch4.txt") }) else {
            return XCTFail("fixture source missing from catalog")
        }

        // Simulate a crash/interruption after the new fingerprint was written
        // but before the processing generation completed.
        try catalog.setStatus(fileID: row.id, status: "pending")

        let retried = try indexer.indexRoot(root)
        XCTAssertEqual(retried, 1,
                       "pending work must be retried even if size/mtime are unchanged")
    }

    func testMissingSweepMarksRemovedFilesAfterNoFollowValidation() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        let target = root.appendingPathComponent("School/csc151-ch4.txt")
        guard let row = try catalog.allFiles().first(where: { $0.path == target.path }) else {
            return XCTFail("fixture source missing from catalog")
        }
        try FileManager.default.removeItem(at: target)

        XCTAssertEqual(try indexer.indexRoot(root), 0)
        XCTAssertEqual(try catalog.allFiles().first(where: { $0.id == row.id })?.status, "missing")
    }
}
