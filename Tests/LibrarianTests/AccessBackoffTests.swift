import Foundation
import XCTest
@testable import LibrarianCore

final class AccessBackoffTests: XCTestCase {
    func testRepeatedFailureUpdatesOneRowWithBackoff() throws {
        let catalog = try TestSupport.makeCatalog()
        let now = 1_800_000_000.0
        let prefix = "/repo/private-cache"

        try catalog.recordAccessBackoff(prefix: prefix, reason: "permission-denied", now: now)
        try catalog.recordAccessBackoff(prefix: prefix, reason: "permission-denied", now: now + 1)

        let rows = try catalog.accessBackoffEntries()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].prefix, prefix)
        XCTAssertEqual(rows[0].attempts, 2)
        XCTAssertGreaterThan(rows[0].retryAfter, now + 31)
    }

    func testPermissionCachePrunesToConfiguredBound() throws {
        let catalog = try TestSupport.makeCatalog()
        for index in 0..<80 {
            try catalog.recordAccessBackoff(
                prefix: "/repo/denied/\(index)", reason: "permission-denied",
                now: Double(index), maximumEntries: 32)
        }
        let rows = try catalog.accessBackoffEntries(limit: 1_024)
        XCTAssertLessThanOrEqual(rows.count, 32)
        XCTAssertTrue(rows.contains { $0.prefix == "/repo/denied/79" })
    }

    func testAutomaticScanSkipsBackedOffPrefixWithoutMarkingChildrenMissing() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backoff-root-\(UUID().uuidString)")
        let denied = root.appendingPathComponent("denied")
        let readable = root.appendingPathComponent("readable")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deniedFile = denied.appendingPathComponent("kept.txt")
        let readableFile = readable.appendingPathComponent("fresh.txt")
        try "keep me".write(to: deniedFile, atomically: true, encoding: .utf8)
        try "fresh".write(to: readableFile, atomically: true, encoding: .utf8)

        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        var manualOptions = ScalableIndexSession.Options()
        manualOptions.updateSimilarity = false
        let manual = ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: manualOptions)
        _ = try manual.indexRoot(root)
        XCTAssertEqual(try catalog.storedState(forPath: deniedFile.path)?.status, "indexed")

        try catalog.recordAccessBackoff(
            prefix: denied.path, reason: "permission-denied",
            now: Date().timeIntervalSince1970)

        var automaticOptions = manualOptions
        automaticOptions.respectAccessBackoff = true
        let automatic = ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: automaticOptions)
        let result = try automatic.indexRoot(root)

        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(try catalog.storedState(forPath: deniedFile.path)?.status, "indexed",
                       "backed-off descendants must not become false missing rows")
        XCTAssertEqual(try catalog.storedState(forPath: readableFile.path)?.status, "indexed")

        // Manual cleanup is an explicit retry and clears the active backoff.
        _ = try manual.indexRoot(root)
        XCTAssertTrue(try catalog.activeAccessBackoffEntries().isEmpty)
    }
}
