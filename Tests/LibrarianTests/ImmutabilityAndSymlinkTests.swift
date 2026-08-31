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

    /// Reviewer finding (deleg_690c9bc4 Q1): a bare "/" (or trailing-slash)
    /// root must never produce "//name" spellings. Pins the enumerate
    /// display-path contract at the pathological input.
    func testRootSlashSpellingNeverDoubleSlashes() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slashroot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "x".write(to: dir.appendingPathComponent("leaf.txt"), atomically: true, encoding: .utf8)

        // Trailing-slash root.
        var items = try SourceBroker.enumerate(root: URL(fileURLWithPath: dir.path + "/"))
        XCTAssertTrue(items.contains { $0.path == dir.path + "/leaf.txt" },
                      "got \(items.map { $0.path })")

        // Bare "/" root: join must yield "/tmp-…/leaf.txt"-style single slashes.
        let tmpRoot = URL(fileURLWithPath: "/")
        items = try SourceBroker.enumerate(root: tmpRoot, maxDepth: 0)
        for i in items where i.path.contains("//") {
            XCTFail("double slash from / root: \(i.path)")
        }
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

    func testIsDirectoryUsesNoFollowMetadataForProtectedDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("directory-metadata-\(UUID().uuidString)")
        let protected = root.appendingPathComponent("protected")
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: protected.path)
            try? FileManager.default.removeItem(at: root)
        }

        // Reading a directory is forbidden, but lstat of the directory entry is
        // still safe metadata and must remain usable for traversal decisions.
        try FileManager.default.setAttributes([.posixPermissions: 0],
                                              ofItemAtPath: protected.path)
        let broker = SourceBroker()
        XCTAssertTrue(broker.isDirectory(at: protected.path))
        XCTAssertFalse(broker.isDirectory(at: protected.appendingPathComponent("missing").path))

        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: protected)
        XCTAssertFalse(broker.isDirectory(at: alias.path),
                      "directory checks must not follow a final symlink")
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

    func testIntermediateSymlinkPathIsNeverOpened() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("intermediate-link-\(UUID().uuidString)")
        let outside = dir.appendingPathComponent("outside")
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try SourceBroker().boundedRead(
            link.appendingPathComponent("secret.txt").path, limit: 64)) { error in
            guard case BrokerError.isSymlink = error else {
                return XCTFail("expected intermediate symlink refusal, got \(error)")
            }
        }
    }

    func testCompleteSnapshotRejectsReplacementDuringRead() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("snapshot-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let victim = dir.appendingPathComponent("payload.bin")
        try Data(repeating: 0x41, count: 512 * 1024).write(to: victim)
        var replaced = false
        XCTAssertThrowsError(try SourceBroker(maxSnapshotBytes: 2 * 1024 * 1024)
            .streamCompleteSnapshot(victim.path) { data, isLast in
                guard !isLast, !replaced else { return }
                replaced = true
                try Data(repeating: 0x42, count: data.count)
                    .write(to: victim, options: .atomic)
            }) { error in
                guard case BrokerError.changedDuringRead = error else {
                    return XCTFail("expected changedDuringRead, got \(error)")
                }
            }
    }

    func testSymlinkRootIsNeverTraversed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symlink-root-\(UUID().uuidString)")
        let target = root.appendingPathComponent("target")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try "secret".write(to: target.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(try SourceBroker.enumerate(root: alias).isEmpty)
    }

    func testIntermediateSymlinkInSelectedRootIsNeverTraversed() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("symlink-root-component-\(UUID().uuidString)")
        let outside = root.appendingPathComponent("outside")
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "secret".write(to: outside.appendingPathComponent("secret.txt"),
                           atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(try SourceBroker.enumerate(
            root: alias.appendingPathComponent("nested")).isEmpty)
    }
}
