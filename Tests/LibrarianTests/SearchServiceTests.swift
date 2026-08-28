import XCTest
@testable import LibrarianCore

final class SearchServiceTests: XCTestCase {
    func testExactSearchFiltersUseVirtualCatalogState() throws {
        let catalog = try TestSupport.makeCatalog(tag: "search-filters")
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let newDate = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            ("old", "/tmp/old.txt", oldDate, ["School/CSC-151"], 0.3),
            ("new", "/tmp/new.txt", newDate, ["Projects"], 0.9),
            ("plain", "/tmp/plain.txt", newDate, ["Documents"], 0.9),
        ]
        for (index, row) in rows.enumerated() {
            try catalog.upsertFile(
                identity: FileIdentity(path: row.1, volumeUUID: nil, fileID: UInt64(index + 1),
                                       size: 5, mtime: row.2, ctime: row.2,
                                       kind: .text, isSymlink: false),
                id: row.0)
            try catalog.setStatus(fileID: row.0, status: "indexed")
            try catalog.saveText(fileID: row.0, body: "shared needle", extractor: "test")
            try catalog.saveClassification(
                Classification(fileID: row.0, categories: row.3, description: "",
                               confidence: row.4, reasonCodes: ["test"]),
                classifier: "test")
        }
        try catalog.recordHash(fileID: "old", size: 5, sha256: Data([1]))
        try catalog.recordHash(fileID: "new", size: 5, sha256: Data([1]))
        try catalog.recordHash(fileID: "plain", size: 5, sha256: Data([2]))

        let service = SearchService(catalog: catalog, enableLocalEmbeddings: false)
        XCTAssertEqual(
            Set(try service.search("needle", filters: [.category("School")]).map(\.fileID)),
            Set(["old"]))
        XCTAssertEqual(
            Set(try service.search("needle", filters: [.after(oldDate)]).map(\.fileID)),
            Set(["new", "plain"]))
        XCTAssertEqual(
            Set(try service.search("needle", filters: [.before(newDate)]).map(\.fileID)),
            Set(["old"]))
        XCTAssertEqual(
            Set(try service.search("needle", filters: [.duplicatesOnly]).map(\.fileID)),
            Set(["old", "new"]))
        XCTAssertEqual(
            Set(try service.search("needle", filters: [.lowConfidence]).map(\.fileID)),
            Set(["old"]))
    }
}
