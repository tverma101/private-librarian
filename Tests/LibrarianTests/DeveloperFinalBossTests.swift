import XCTest
@testable import LibrarianCore

final class DeveloperFinalBossTests: XCTestCase {
    func testKnownBuildAndCacheDirectoriesAreExcludedByDefault() {
        let names = [
            "node_modules", "DerivedData", "build", ".build", "dist", "out", "obj", "target",
            "WebKitBuild", "buck-out", ".cxx", ".ccache", ".sccache",
            "bazel-bin", "bazel-out", "bazel-testlogs",
            "cmake-build-debug", "cmake-build-release", "cmake-build-relwithdebinfo",
            ".gradle", ".m2", ".npm", ".yarn", ".pnpm-store", ".cargo", ".rustup",
            ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite",
            ".mozbuild"
        ]
        for name in names {
            XCTAssertTrue(OnboardingExclusions.isExcludedDirectoryName(name), name)
        }
        // Human folder names are not sacrificed just because a tool sometimes
        // uses the same word for output.
        XCTAssertFalse(OnboardingExclusions.isExcludedDirectoryName("coverage"))
    }

    func testConfigurationSpecificBuildDirectoryPatternsAreExcluded() {
        for name in [
            "obj-x86_64-apple-darwin23.0.0",
            "obj-firefox-release",
            "cmake-build-debug",
            "cmake-build-release-arm64",
            "bazel-out",
            "bazel-bin",
            "bazel-testlogs",
            "bazel-private_librarian"
        ] {
            XCTAssertTrue(OnboardingExclusions.isExcludedDirectoryName(name), name)
        }
        XCTAssertFalse(OnboardingExclusions.isExcludedDirectoryName("objective-c-notes"))
        XCTAssertFalse(OnboardingExclusions.isExcludedDirectoryName("output-notes"))
    }

    func testBrowserStyleGeneratedTreesAndTransientFilesAreNeverEnumerated() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("developer-final-boss-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let authored = root.appendingPathComponent("src/browser/main.cc")
        let generated = [
            root.appendingPathComponent("out/Default/obj/blink/generated.o"),
            root.appendingPathComponent("obj-firefox-release/dom/generated.o"),
            root.appendingPathComponent("cmake-build-profile/CMakeFiles/generated.o"),
            root.appendingPathComponent("bazel-browser/darwin-fastbuild/bin/generated"),
            root.appendingPathComponent("target/debug/deps/generated.rlib"),
            root.appendingPathComponent("node_modules/pkg/dist/index.js"),
            root.appendingPathComponent("WebKitBuild/Release/WebKit.framework/fake")
        ]
        let transient = [
            root.appendingPathComponent("browser.dmg.crdownload"),
            root.appendingPathComponent("safari-file.download"),
            root.appendingPathComponent("archive.zip.part"),
            root.appendingPathComponent("firefox-file.partial"),
            root.appendingPathComponent(".DS_Store"),
            root.appendingPathComponent("._main.cc"),
            root.appendingPathComponent("~$notes.docx")
        ]
        try FileManager.default.createDirectory(
            at: authored.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "int main() { return 0; }".write(to: authored, atomically: true, encoding: .utf8)
        for file in generated {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "generated".write(to: file, atomically: true, encoding: .utf8)
        }
        for file in transient {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "temporary".write(to: file, atomically: true, encoding: .utf8)
        }

        let items = try SourceBroker.enumerate(
            root: root,
            excludedDirectoryNames: OnboardingExclusions.defaultDirectoryNames)
        let paths = Set(items.map(\.path))
        XCTAssertTrue(paths.contains(authored.path))
        for file in generated + transient {
            XCTAssertFalse(paths.contains(file.path), file.path)
        }
    }

    func testCompletedBrowserDownloadBecomesIndexableAfterFinalRename() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("completed-download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let partial = root.appendingPathComponent("browser.dmg.crdownload")
        let completed = root.appendingPathComponent("browser.dmg")
        try Data("synthetic installer payload".utf8).write(to: partial)

        var paths = Set(try SourceBroker.enumerate(
            root: root,
            excludedDirectoryNames: OnboardingExclusions.defaultDirectoryNames).map(\.path))
        XCTAssertFalse(paths.contains(partial.path))
        XCTAssertTrue(LiveExclusions.isExcluded(path: partial.path, prefixes: []))

        try FileManager.default.moveItem(at: partial, to: completed)
        paths = Set(try SourceBroker.enumerate(
            root: root,
            excludedDirectoryNames: OnboardingExclusions.defaultDirectoryNames).map(\.path))
        XCTAssertTrue(paths.contains(completed.path))
        XCTAssertFalse(LiveExclusions.isExcluded(path: completed.path, prefixes: []))
        XCTAssertEqual(SourceBroker.classify(path: completed.path), .diskImage)
    }

    func testLiveEventsRejectBuildPatternsAndTransientFilesBeforeQueueing() {
        let excluded = [
            "/repo/out/Default/obj/blink/foo.o",
            "/repo/obj-firefox-release/dom/foo.o",
            "/repo/cmake-build-debug/CMakeFiles/foo.o",
            "/repo/bazel-out/darwin-fastbuild/bin/foo",
            "/repo/target/debug/deps/foo.rlib",
            "/repo/node_modules/pkg/index.js",
            "/repo/download.dmg.crdownload",
            "/repo/safari.download",
            "/repo/video.mp4.part",
            "/repo/firefox.partial",
            "/repo/.DS_Store",
            "/repo/._main.swift",
            "/repo/~$notes.docx"
        ]
        for path in excluded {
            XCTAssertTrue(LiveExclusions.isExcluded(path: path, prefixes: []), path)
        }
        XCTAssertFalse(LiveExclusions.isExcluded(path: "/repo/src/browser/main.cc", prefixes: []))
        XCTAssertFalse(LiveExclusions.isExcluded(path: "/repo/docs/output-notes.md", prefixes: []))
    }

    func testCompilerStormCollapsesToOneBoundedReconciliationMarker() {
        let queue = LiveCoalescingQueue(debounceInterval: 0.8, maxPendingPaths: 32)
        let events = (0..<10_000).map {
            LiveRawEvent(path: "/repo/generated/file-\($0).o",
                         flags: LiveRawEvent.itemModified,
                         eventId: UInt64($0 + 1))
        }
        queue.ingest(events)

        XCTAssertTrue(queue.hasPendingFullRescan)
        XCTAssertEqual(queue.pendingCount, 1, "overflow must not retain thousands of unique paths")
        let batch = queue.drain()
        XCTAssertEqual(batch?.needsFullRescan, true)
        XCTAssertEqual(batch?.paths.count, 0)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testQueueAcceptsAuthoredSourceAgainAfterStormDrain() {
        let queue = LiveCoalescingQueue(debounceInterval: 0.8, maxPendingPaths: 4)
        queue.ingest((0..<20).map {
            LiveRawEvent(path: "/repo/out/file-\($0).o", eventId: UInt64($0 + 1))
        })
        XCTAssertTrue(queue.drain()?.needsFullRescan == true)

        let source = "/repo/src/browser/main.cc"
        queue.ingest([LiveRawEvent(path: source, flags: LiveRawEvent.itemModified, eventId: 100)])
        let batch = queue.drain()
        XCTAssertEqual(batch?.needsFullRescan, false)
        XCTAssertEqual(batch?.paths, [source])
    }
}
