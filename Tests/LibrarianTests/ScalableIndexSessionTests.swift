import Foundation
import XCTest
@testable import LibrarianCore

final class ScalableIndexSessionTests: XCTestCase {
    func testStreamingEnumerationNeverExceedsConfiguredBatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("streaming-enumeration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for directory in 0..<20 {
            let dir = root.appendingPathComponent("src-\(directory)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for file in 0..<100 {
                try "let value = \(file)".write(
                    to: dir.appendingPathComponent("file-\(file).swift"),
                    atomically: true, encoding: .utf8)
            }
        }

        var batches = 0
        var maximumBatch = 0
        var observed = 0
        let discovered = try SourceBroker.enumerateBatches(
            root: root, batchSize: 64) { batch in
                batches += 1
                maximumBatch = max(maximumBatch, batch.count)
                observed += batch.count
                return true
            }

        XCTAssertEqual(discovered, 2_000)
        XCTAssertEqual(observed, 2_000)
        XCTAssertGreaterThan(batches, 1)
        XCTAssertLessThanOrEqual(maximumBatch, 64)
    }

    func testLargeDirectoryRemainsDeterministicWithoutHeapSizedListing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("large-streaming-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in stride(from: 5_000, through: 1, by: -1) {
            try Data("\(index)".utf8).write(
                to: root.appendingPathComponent(String(format: "file-%05d.txt", index)))
        }

        var paths: [String] = []
        let discovered = try SourceBroker.enumerateBatches(root: root, batchSize: 127) { batch in
            paths.append(contentsOf: batch.map(\.path))
            return true
        }

        XCTAssertEqual(discovered, 5_000)
        XCTAssertEqual(paths, paths.sorted(), "large-directory traversal must stay deterministic")
    }

    func testMaxItemsStopsDiscoveryAndDeliversTheFinalBoundedBatch() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("limited-streaming-directory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<40 {
            try Data("\(index)".utf8).write(
                to: root.appendingPathComponent(String(format: "file-%03d.txt", index)))
        }

        var observed = 0
        var batches = 0
        let discovered = try SourceBroker.enumerateBatches(
            root: root, maxItems: 3, batchSize: 100) { batch in
                batches += 1
                observed += batch.count
                return true
            }

        XCTAssertEqual(discovered, 3)
        XCTAssertEqual(observed, 3)
        XCTAssertEqual(batches, 1)
    }

    func testCancellationStopsDuringLargeDirectoryCursorConstruction() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cancelled-directory-cursor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<1_000 {
            try Data([UInt8(index & 0xff)]).write(
                to: root.appendingPathComponent(String(format: "file-%04d.txt", index)))
        }

        var checks = 0
        var callbackCalls = 0
        let discovered = try SourceBroker.enumerateBatches(
            root: root,
            batchSize: 64,
            continuePredicate: {
                checks += 1
                return checks < 100
            }
        ) { _ in
            callbackCalls += 1
            return true
        }

        XCTAssertEqual(discovered, 0)
        XCTAssertGreaterThanOrEqual(checks, 100)
        XCTAssertEqual(callbackCalls, 0)
    }

    func testUnavailableRootProducesExplicitCompletionReason() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("missing-root-\(UUID().uuidString)")
        var callback: (path: String, reason: String)?
        let discovered = try SourceBroker.enumerateBatches(
            root: root,
            onRootUnavailable: { path, reason in callback = (path, reason) }
        ) { _ in true }

        XCTAssertEqual(discovered, 0)
        XCTAssertEqual(callback?.path, root.path)
        XCTAssertFalse(callback?.reason.isEmpty ?? true)

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        var options = ScalableIndexSession.Options()
        options.updateSimilarity = false
        let result = try ScalableIndexSession(
            broker: SourceBroker(), catalog: catalog, indexer: indexer, options: options)
            .indexRoot(root)
        XCTAssertEqual(result.completion, .rootUnavailable)
        XCTAssertEqual(result.rootPath, root.path)
        XCTAssertEqual(result.missingMarked, 0)
        let summary = try catalog.projectSemanticSummaries().first
        XCTAssertEqual(summary?.complete, false)
        XCTAssertTrue(summary?.summary.contains("status partial") == true)
    }

    func testCancellationSkipsMissingSweepAndResumeConverges() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cancellable-root-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<240 {
            try "source \(index)".write(
                to: root.appendingPathComponent(String(format: "%04d.txt", index)),
                atomically: true, encoding: .utf8)
        }

        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        var options = ScalableIndexSession.Options()
        options.batchSize = 32
        options.updateSimilarity = false
        let session = ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: options)

        let first = try session.indexRoot(root)
        XCTAssertFalse(first.cancelled)
        XCTAssertEqual(first.scanned, 240)

        let removed = root.appendingPathComponent("0239.txt")
        try FileManager.default.removeItem(at: removed)

        let token = IndexCancellationToken()
        let partial = try session.indexRoot(root, cancellation: token) { progress in
            if progress.scanned >= 70 { token.cancel(reason: .paused) }
        }
        XCTAssertTrue(partial.cancelled)
        XCTAssertTrue(partial.paused)
        XCTAssertEqual(partial.completion, .paused)
        XCTAssertGreaterThanOrEqual(partial.scanned, 70)
        XCTAssertLessThan(partial.scanned, 239)

        // An incomplete traversal cannot prove deletion. The old catalog row
        // must stay non-missing until a complete resumed pass reaches the sweep.
        XCTAssertNotEqual(try catalog.storedState(forPath: removed.path)?.status, "missing")

        indexer.resetWorkMetrics()
        let resumed = try session.indexRoot(root)
        XCTAssertFalse(resumed.cancelled)
        XCTAssertEqual(resumed.missingMarked, 1)
        XCTAssertEqual(try catalog.storedState(forPath: removed.path)?.status, "missing")
        // All remaining files were unchanged; resume must be an incremental
        // scan rather than a repeat of expensive analysis.
        XCTAssertEqual(resumed.processed, 0)
        XCTAssertEqual(indexer.workMetrics.visionCalls, 0)
        XCTAssertEqual(indexer.workMetrics.ocrCalls, 0)
        XCTAssertEqual(indexer.workMetrics.textEmbedCalls, 0)
    }
}
