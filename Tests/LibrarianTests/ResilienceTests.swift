import XCTest
@testable import LibrarianCore

/// Plan §42/§43/§44 — parser-crash containment, catalog-loss recovery,
/// original-loss isolation. Plus catalog encryption guarantees (§14).
final class ResilienceTests: XCTestCase {

    func testMalformedFilesDoNotStopIndexing() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        // truncated.pdf, fake.jpg, corrupt.zip are all in the tree.
        let n = try indexer.indexRoot(root)
        XCTAssertGreaterThan(n, 0, "indexing must complete despite malformed inputs")

        let files = try catalog.allFiles()
        for name in ["truncated.pdf", "fake.jpg", "corrupt.zip"] {
            let rec = files.first { $0.path.hasSuffix(name) }
            XCTAssertNotNil(rec, "\(name) should be recorded")
            // It was processed without killing the run; status is indexed or failed — never missing.
            XCTAssertTrue(["indexed", "failed"].contains(rec?.status ?? ""), "\(name): \(rec?.status ?? "?")")
        }
        // Healthy files still got through.
        XCTAssertTrue(files.contains { $0.path.hasSuffix("csc151-ch4.txt") })
    }

    func testCatalogDeletionLeavesOriginalsIntact() throws {
        // Plan §43: the catalog is derivative, disposable state.
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let before = try TestSupport.snapshot(root: root)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("catalog-loss-\(UUID().uuidString)")
        let dbPath = dir.appendingPathComponent("catalog.db").path
        _ = try Catalog(path: dbPath, key: Data("k".utf8))
        try FileManager.default.removeItem(atPath: dbPath)

        // Rebuild from sources works and originals never changed.
        let catalog = try Catalog(path: dbPath, key: Data("k".utf8))
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        let n = try indexer.indexRoot(root)
        XCTAssertGreaterThan(n, 0)
        XCTAssertEqual(before, try TestSupport.snapshot(root: root))
    }

    func testOriginalLossIsRecordedNotRepaired() throws {
        // Plan §44: deleting an original externally → catalog marks missing;
        // app never tries to reconstruct or replace it.
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        let victim = root.appendingPathComponent("School/mat171-worksheet.txt")
        try FileManager.default.removeItem(at: victim) // external deletion

        // Re-scan: the file's record must be marked missing, nothing recreated.
        _ = try indexer.indexRoot(root)
        let files = try catalog.allFiles()
        let rec = files.first { $0.path.hasSuffix("School/mat171-worksheet.txt") }
        XCTAssertEqual(rec?.status, "missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
    }

    /// Reviewer finding (deleg_690c9bc4 Q4): an unreadable directory must NOT
    /// count as deletion. EACCES means "can't look right now" — the sweep may
    /// only mark 'missing' when lstat proves absence (ENOENT/ENOTDIR).
    func testUnreadableDirectoryDoesNotMarkFilesMissing() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        // Make School/ unreadable (not deleted): enumerate sees nothing
        // inside it, and lstat of children fails with EACCES.
        let school = root.appendingPathComponent("School")
        var st = stat()
        precondition(lstat(school.path, &st) == 0)
        let originalMode = st.st_mode & 0o7777
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: school.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: originalMode], ofItemAtPath: school.path) }
        _ = try indexer.indexRoot(root)

        let files = try catalog.allFiles()
        let worksheet = files.first { $0.path.hasSuffix("School/mat171-worksheet.txt") }
        XCTAssertEqual(worksheet?.status, "indexed",
                       "EACCES is not deletion — file must stay indexed, not missing")
    }

    func testCatalogIsEncryptedOnDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("enc-\(UUID().uuidString)")
        let dbPath = dir.appendingPathComponent("catalog.db").path
        let catalog = try Catalog(path: dbPath, key: Data("secret-key".utf8))
        // Seed a parent file row first — text_content carries an FK to files.
        try catalog.upsertFile(identity: FileIdentity(
            path: dir.appendingPathComponent("sample.txt").path,
            volumeUUID: nil, fileID: 1, size: 20,
            mtime: Date(), ctime: Date(), kind: .text, isSymlink: false), id: "file_abc123")
        try catalog.saveText(fileID: "file_abc123", body: "very private content", extractor: "test")

        XCTAssertFalse(Catalog.onDiskHeaderIsPlaintextSQLite(path: dbPath),
                       "catalog file must NOT have a plaintext SQLite header")
        // And the raw bytes don't contain the plaintext either.
        let raw = try Data(contentsOf: URL(fileURLWithPath: dbPath))
        XCTAssertNil(raw.range(of: Data("very private content".utf8)), "plaintext found in encrypted catalog!")
    }

    func testWrongKeyIsRejected() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("wrongkey-\(UUID().uuidString)")
        let dbPath = dir.appendingPathComponent("catalog.db").path
        _ = try Catalog(path: dbPath, key: Data("right-key".utf8))

        XCTAssertThrowsError(try Catalog(path: dbPath, key: Data("wrong-key".utf8))) { err in
            guard case Catalog.CatalogError.keyRejected = err else {
                return XCTFail("expected keyRejected, got \(err)")
            }
        }
    }
}
