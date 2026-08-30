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
            if progress.scanned >= 70 { token.cancel() }
        }
        XCTAssertTrue(partial.cancelled)
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
