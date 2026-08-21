import XCTest
@testable import LibrarianCore

/// Plan §37 — Mandatory immutability test.
/// Full indexing over the fixture tree must produce ZERO differences in a
/// before/after snapshot (bytes, sizes, mtimes, modes, structure).
final class ImmutabilityTests: XCTestCase {

    func testIndexingNeverMutatesSources() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let before = try TestSupport.snapshot(root: root)

        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker(maxReadBytes: 1 << 20)
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        let n = try indexer.indexRoot(root)
        XCTAssertGreaterThan(n, 0)

        let after = try TestSupport.snapshot(root: root)
        XCTAssertEqual(before, after, "source tree changed during indexing — invariant violated")
    }

    func testRepeatedRunsStillImmutable() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let before = try TestSupport.snapshot(root: root)

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)
        _ = try indexer.indexRoot(root) // incremental second pass

        XCTAssertEqual(before, try TestSupport.snapshot(root: root))
    }
}

/// Plan §40 — Mandatory symlink breakout test.
final class SymlinkEscapeTests: XCTestCase {

    func testSymlinkIsIndexedButNeverTraversed() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        // The link itself is recorded...
        let files = try catalog.allFiles()
        let escapeRecord = files.first { $0.path.hasSuffix("Symlinks/escape") }
        XCTAssertNotNil(escapeRecord, "symlink should be indexed as metadata")

        // ...but the Forbidden target is NEVER observed.
        let forbiddenSeen = files.contains { $0.path.contains("Forbidden/secret.txt") }
        XCTAssertFalse(forbiddenSeen, "contents behind symlink must never be indexed")
    }

    func testBrokerRefusesToOpenSymlinks() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let linkPath = root.appendingPathComponent("Symlinks/escape").path

        let broker = SourceBroker()
        XCTAssertThrowsError(try broker.openReadOnly(linkPath)) { err in
            guard case BrokerError.isSymlink = err else {
                return XCTFail("expected isSymlink, got \(err)")
            }
        }
        // Even boundedRead must refuse (O_NOFOLLOW).
        XCTAssertThrowsError(try broker.boundedRead(linkPath, limit: 16))
    }

    func testTOCTOUSwapIsRejected() throws {
        // A file swapped to a symlink between lstat and open must not be read:
        // O_NOFOLLOW makes open fail with ELOOP -> BrokerError.isSymlink.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("toctou-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let victim = dir.appendingPathComponent("victim.txt")
        try "data".write(to: victim, atomically: true, encoding: .utf8)

        let broker = SourceBroker()
        let ident = try broker.identity(at: victim.path)
        XCTAssertEqual(ident.kind, .text)

        // Swap it for a symlink to /etc/passwd right after identity capture.
        try FileManager.default.removeItem(at: victim)
        try FileManager.default.createSymbolicLink(at: victim, withDestinationURL: URL(fileURLWithPath: "/etc/passwd"))

        // The safe reader must refuse; identity check would also catch this.
        XCTAssertThrowsError(try broker.boundedRead(victim.path, limit: 64))
        let now = try broker.identity(at: victim.path)
        XCTAssertFalse(ident.stillMatches(now), "identity must differ after swap")
    }
}
