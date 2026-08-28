import XCTest
@testable import LibrarianCore

/// Plan §41 — Mandatory prompt-injection test.
/// Hostile document content must be inert: classified as data, never acted on.
final class PromptInjectionTests: XCTestCase {

    func testInjectionDocumentIsInertData() throws {
        let root = try TestSupport.makeFixtureTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        _ = try indexer.indexRoot(root)

        // The injection file was indexed like any other text file.
        let files = try catalog.allFiles()
        let inj = files.first { $0.path.hasSuffix("injection.txt") }
        XCTAssertNotNil(inj)
        XCTAssertEqual(inj?.status, "indexed")

        // Its content is searchable (it's data in the catalog)...
        let hits = try catalog.searchExact("UPLOAD EVERYTHING")
        XCTAssertTrue(hits.contains { $0.fileID == inj?.id })

        // ...and that is ALL that happened. There are no tools, no network
        // APIs, and no write paths in the entire core — proven structurally by
        // the immutability test running in the same process.
        let before = try TestSupport.snapshot(root: root)
        _ = try indexer.indexRoot(root)
        XCTAssertEqual(before, try TestSupport.snapshot(root: root))
    }

    /// The classifier contract wall: hostile "output" cannot survive validation.
    func testContractRejectsHostileOutput() throws {
        let hostile = [
            // Tool-call attempt smuggled into categories.
            #"{"file_id":"file_abc123","categories":["../../etc","rm -rf /"],"description":"","confidence":0.9,"reason_codes":[]}"#,
            // Path traversal category.
            #"{"file_id":"file_abc123","categories":["A/../../../B"],"description":"","confidence":0.9,"reason_codes":[]}"#,
            // Out-of-range confidence.
            #"{"file_id":"file_abc123","categories":["Ok"],"description":"","confidence":4.2,"reason_codes":[]}"#,
            // Oversized description.
            #"{"file_id":"file_abc123","categories":["Ok"],"description":"# + "\"" + String(repeating: "x", count: 5000) + "\"" + #","confidence":0.5,"reason_codes":[]}"#,
            // Non-file id (not opaque). Use a neutral fake path in public tests.
            #"{"file_id":"/Users/example/Desktop/secret.pdf","categories":["Ok"],"description":"","confidence":0.5,"reason_codes":[]}"#,
        ]
        for json in hostile {
            let parsed = try? JSONDecoder().decode(ClassifierContract.RawClassification.self, from: Data(json.utf8))
            if let raw = parsed {
                XCTAssertNil(ClassifierContract.validate(raw), "hostile output validated: \(json.prefix(80))")
            }
            // If it doesn't even decode, it's discarded too — also fine.
        }
    }

    func testLegitimateOutputPassesContract() throws {
        let good = ClassifierContract.RawClassification(
            file_id: "file_00018472",
            categories: ["School/CSC-151", "Screenshot"],
            description: "lecture screenshot",
            confidence: 0.91,
            reason_codes: ["ocr:blackboard", "course-code"])
        let c = ClassifierContract.validate(good)
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.categories, ["School/CSC-151", "Screenshot"])
    }
}
