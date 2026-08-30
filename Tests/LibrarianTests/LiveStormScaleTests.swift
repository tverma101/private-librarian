import XCTest
@testable import LibrarianCore

final class LiveStormScaleTests: XCTestCase {
    func testHundredThousandUniqueEventsCollapseAtHardMemoryBound() {
        let queue = LiveCoalescingQueue(debounceInterval: 0.01, maxPendingPaths: 128)
        let events = (0..<100_000).map {
            LiveRawEvent(path: "/repo/out/Default/obj/generated-\($0).o",
                         flags: LiveRawEvent.itemModified,
                         eventId: UInt64($0 + 1))
        }

        queue.ingest(events)

        XCTAssertEqual(queue.pendingCount, 1,
                       "overflow must collapse to one reconciliation marker")
        XCTAssertTrue(queue.hasPendingFullRescan)
        XCTAssertLessThanOrEqual(queue.metrics.peakPendingPaths, 128)
        XCTAssertEqual(queue.metrics.stormCollapses, 1)

        let storm = queue.drain()
        XCTAssertEqual(storm?.needsFullRescan, true)
        XCTAssertTrue(storm?.paths.isEmpty == true)

        // The queue must recover after the storm rather than remaining in a
        // permanent rescan state and losing later authored-source changes.
        let source = "/repo/src/browser/main.cc"
        queue.ingest([LiveRawEvent(path: source,
                                   flags: LiveRawEvent.itemModified,
                                   eventId: 100_001)])
        let later = queue.drain()
        XCTAssertEqual(later?.needsFullRescan, false)
        XCTAssertEqual(later?.paths, [source])
    }

    func testRepeatedDroppedEventBatchesAreRateLimitedToOneImmediateReconciliation() throws {
        let catalog = try TestSupport.makeCatalog()
        var options = LiveIndexCoordinator.Options()
        options.reconciliationCooldown = 60
        let root = URL(fileURLWithPath: "/synthetic/browser-source")
        let coordinator = LiveIndexCoordinator(
            catalog: catalog,
            indexer: Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler()),
            broker: SourceBroker(), scheduler: Scheduler(), roots: [root], options: options)

        var reconciliations = 0
        coordinator.testFullRescanHandler = { reconciliations += 1 }

        for eventID in 1...3 {
            coordinator.ingest(events: [
                LiveRawEvent(path: root.path,
                             flags: LiveRawEvent.mustScanSubDirs,
                             eventId: UInt64(eventID))
            ])
            _ = coordinator.flushForTesting()
        }

        XCTAssertEqual(reconciliations, 1,
                       "repeated dropped-event storms must not tight-loop whole-root scans")
        XCTAssertEqual(coordinator.liveMetrics.fullReconciliations, 1)
    }
}
