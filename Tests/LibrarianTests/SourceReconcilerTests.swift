import XCTest
@testable import LibrarianCore

/// The reconcile pass decides which known rows count as gone. A false
/// "missing" verdict silently empties Smart Groups, so every non-deletion
/// failure mode must classify as keep-as-is, not as deletion. FileID is never
/// compared: it is path-derived, so alias differences must not read as
/// deletions, and a modified file at the same path still exists.
final class SourceReconcilerTests: XCTestCase {
    private func identity(fileID: UInt64, volumeUUID: String? = "vol-1") -> FileIdentity {
        FileIdentity(path: "/tmp/root/report.pdf", volumeUUID: volumeUUID, fileID: fileID,
                     size: 10, mtime: Date(), ctime: Date(), kind: .text, isSymlink: false)
    }

    private func classify(throwing error: Error? = nil,
                          returning identity: FileIdentity? = nil,
                          leaseTargetURL: URL? = URL(fileURLWithPath: "/tmp/root/report.pdf")
    ) -> SourceReconciler.Outcome {
        SourceReconciler.classify(leaseTargetURL: leaseTargetURL) { _ in
            if let error { throw error }
            return identity ?? self.identity(fileID: 42)
        }
    }

    func testExistingPathIsCurrentRegardlessOfInodeOrAlias() {
        XCTAssertEqual(classify(returning: identity(fileID: 42)), .current)
        XCTAssertEqual(classify(returning: identity(fileID: 43, volumeUUID: nil)),
                       .current, "a modified file still exists; its row refreshes in place")
        XCTAssertEqual(classify(returning: identity(fileID: 42)), .current)
    }

    func testVanishedPathCountsAsMovedOrDeleted() {
        for error in [BrokerError.statFailed(ENOENT), BrokerError.openFailed(ENOTDIR)] {
            XCTAssertEqual(classify(throwing: error), .movedOrDeleted, "\(error) must read as gone")
        }
    }

    func testPathNoLongerRegularFileMeansRowIsStale() {
        XCTAssertEqual(classify(throwing: BrokerError.notRegularFile), .movedOrDeleted)
        XCTAssertEqual(classify(throwing: BrokerError.isSymlink), .movedOrDeleted)
    }

    func testPermissionDeniedIsNotDeletion() {
        for error in [BrokerError.statFailed(EACCES), BrokerError.openFailed(EPERM)] {
            XCTAssertEqual(classify(throwing: error), .permissionDenied,
                           "\(error) is transient, not deletion")
        }
    }

    func testUnavailableKeepsRowStatus() {
        for error in [BrokerError.statFailed(EIO),
                      BrokerError.snapshotTooLarge(size: 10, limit: 5),
                      BrokerError.changedDuringRead] {
            XCTAssertEqual(classify(throwing: error), .unavailable,
                           "\(error) must keep the row as-is")
        }

        XCTAssertEqual(classify(leaseTargetURL: nil), .unavailable)
    }

    func testIndexedFileCountUnderRootExcludesMissingUnscopedAndOtherRoots() throws {
        let catalog = try TestSupport.makeCatalog()
        let rows: [(String, UInt64, String)] = [
            ("/tmp/root-a/root-a.txt", 1, "indexed"),
            ("/tmp/root-a/sub/deep.txt", 2, "indexed"),
            ("/tmp/root-a/gone.txt", 3, "missing"),
            ("/tmp/root-a/unscoped.txt", 4, "unscoped"),
            ("/tmp/root-b/other.txt", 5, "indexed"),
        ]
        for (path, fileID, status) in rows {
            let id = "count-\(fileID)"
            try catalog.upsertFile(
                identity: FileIdentity(path: path, volumeUUID: nil, fileID: fileID,
                                       size: 10, mtime: Date(), ctime: Date(),
                                       kind: .text, isSymlink: false), id: id)
            try catalog.setStatus(fileID: id, status: status)
        }

        XCTAssertEqual(try catalog.indexedFileCount(under: "/tmp/root-a"), 2)
        XCTAssertEqual(try catalog.indexedFileCount(under: "/tmp/root-a/"), 2, "trailing slash is normalized")
        XCTAssertEqual(try catalog.indexedFileCount(under: "/tmp/root-b"), 1)
        XCTAssertEqual(try catalog.indexedFileCount(under: "/tmp/nowhere"), 0)
    }
}
