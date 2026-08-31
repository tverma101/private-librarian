import Foundation
import XCTest
@testable import LibrarianAppSupport
@testable import LibrarianCore

final class AppRuntimeConfigurationTests: XCTestCase {
    private final class AccessCounter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var begins = 0
        private(set) var ends = 0

        func begin() -> Bool {
            lock.lock(); defer { lock.unlock() }
            begins += 1
            return true
        }

        func end() {
            lock.lock(); defer { lock.unlock() }
            ends += 1
        }
    }

    func testBookmarkLeaseFailsClosedForMissingInvalidAndStaleData() throws {
        let url = URL(fileURLWithPath: "/tmp/authorized-root", isDirectory: true)
        let noOpBegin: SecurityScopedBookmarkLease.BeginAccess = { _ in true }
        let noOpEnd: SecurityScopedBookmarkLease.EndAccess = { _ in }

        XCTAssertThrowsError(try SecurityScopedBookmarkLease(
            bookmarkData: nil,
            resolver: { _ in .init(url: url, isStale: false) },
            beginAccess: noOpBegin,
            endAccess: noOpEnd
        )) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkLease.LeaseError, .missingBookmark)
        }

        XCTAssertThrowsError(try SecurityScopedBookmarkLease(
            bookmarkData: Data([1]),
            resolver: { _ in throw NSError(domain: "fixture", code: 1) },
            beginAccess: noOpBegin,
            endAccess: noOpEnd
        )) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkLease.LeaseError, .invalidBookmark)
        }

        XCTAssertThrowsError(try SecurityScopedBookmarkLease(
            bookmarkData: Data([1]),
            resolver: { _ in .init(url: url, isStale: true) },
            beginAccess: noOpBegin,
            endAccess: noOpEnd
        )) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkLease.LeaseError, .staleBookmark)
        }
    }

    func testValidBookmarkLeaseBalancesAccessAndStaysInsideAuthorizedRoot() throws {
        let counter = AccessCounter()
        let resolved = URL(fileURLWithPath: "/tmp/resolved-root", isDirectory: true)
        var lease: SecurityScopedBookmarkLease? = try SecurityScopedBookmarkLease(
            bookmarkData: Data([7]),
            resolver: { _ in .init(url: resolved, isStale: false) },
            beginAccess: { _ in counter.begin() },
            endAccess: { _ in counter.end() }
        )

        XCTAssertEqual(counter.begins, 1)
        XCTAssertEqual(counter.ends, 0)
        XCTAssertEqual(
            lease?.targetURL(
                for: "/Users/example/Documents/School/note.txt",
                originalRootPath: "/Users/example/Documents"
            )?.path,
            "/tmp/resolved-root/School/note.txt"
        )
        XCTAssertNil(lease?.targetURL(
            for: "/Users/example/Desktop/outside.txt",
            originalRootPath: "/Users/example/Documents"
        ))

        lease = nil
        XCTAssertEqual(counter.ends, 1)
    }

    func testBookmarkLeaseFailsClosedWhenAccessCannotStart() throws {
        let counter = AccessCounter()
        let resolved = URL(fileURLWithPath: "/tmp/denied-root", isDirectory: true)

        XCTAssertThrowsError(try SecurityScopedBookmarkLease(
            bookmarkData: Data([8]),
            resolver: { _ in .init(url: resolved, isStale: false) },
            beginAccess: { _ in
                _ = counter.begin()
                return false
            },
            endAccess: { _ in counter.end() }
        )) { error in
            XCTAssertEqual(error as? SecurityScopedBookmarkLease.LeaseError, .accessDenied)
        }

        XCTAssertEqual(counter.begins, 1)
        XCTAssertEqual(counter.ends, 0, "a lease must not stop access it never started")
    }

    func testLocalTranscriptionSettingReachesIndexerConfigurationOnlyAfterPreflight() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-runtime-asr-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executable = root.appendingPathComponent("whisper-cli")
        let model = root.appendingPathComponent("ggml-base.en.bin")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data([0, 1, 2, 3]).write(to: model)

        var options = Indexer.Options()
        let off = AppLocalTranscription.configure(
            options: &options,
            enabled: false,
            executablePath: executable.path,
            modelPath: model.path
        )
        XCTAssertFalse(options.enableLocalASR, "default/off setting must keep ASR disabled")
        XCTAssertEqual(off.providerID, "disabled")

        let on = AppLocalTranscription.configure(
            options: &options,
            enabled: true,
            executablePath: executable.path,
            modelPath: model.path
        )
        XCTAssertTrue(options.enableLocalASR, "opt-in plus passing preflight must reach Indexer.Options")
        XCTAssertEqual(on.providerID, "whisper.cpp-cli")

        try FileManager.default.removeItem(at: model)
        let unavailable = AppLocalTranscription.configure(
            options: &options,
            enabled: true,
            executablePath: executable.path,
            modelPath: model.path
        )
        XCTAssertFalse(options.enableLocalASR, "failed preflight must fail closed")
        XCTAssertEqual(unavailable.providerID, "disabled")

        guard case .unavailable(let reason) = AppLocalTranscription.preflight(
            executablePath: executable.path,
            modelPath: model.path
        ) else {
            return XCTFail("missing model must report unavailable")
        }
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("model unavailable"))
    }
}
