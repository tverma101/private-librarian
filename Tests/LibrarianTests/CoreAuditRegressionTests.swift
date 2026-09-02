import XCTest

@testable import LibrarianCore

/// Regressions for bugs found in the deep core audit: taxonomy schema,
/// virtual tree assembly, review durability, duplicate-view agreement,
/// screenshot calibration, media gating, text decoding, and decoder bounds.
final class CoreAuditRegressionTests: XCTestCase {

    private func indexTextFile(_ catalog: Catalog, id: String, path: String,
                               categories: [String], confidence: Double) throws {
        try catalog.upsertFile(
            identity: FileIdentity(path: path, volumeUUID: nil, fileID: UInt64(abs(id.hashValue % 100_000)) + 1,
                                   size: 64, mtime: Date(timeIntervalSince1970: 1_700_000_000),
                                   ctime: Date(timeIntervalSince1970: 1_700_000_000),
                                   kind: .text, isSymlink: false),
            id: id)
        try catalog.setStatus(fileID: id, status: "indexed")
        try catalog.saveText(fileID: id, body: "sample body \(id)", extractor: "test")
        try catalog.saveClassification(
            Classification(fileID: id, categories: categories, description: "",
                           confidence: confidence, reasonCodes: ["test"]),
            classifier: "test")
    }

    // MARK: - Hierarchical taxonomy (schema v6)

    func testSiblingCategoriesWithSameNameUnderDifferentParents() throws {
        let catalog = try TestSupport.makeCatalog()
        // "Archive" at the root and "Tax/Archive" share a name but not a
        // parent. The old table-level UNIQUE(name) made the second insert
        // throw, rolling back the entire index commit.
        _ = try catalog.ensureCategory(named: "Archive")
        _ = try catalog.ensureCategory(named: "Tax/Archive")
        _ = try catalog.ensureCategory(named: "Tax/Archive")

        let rows = try catalog.query(
            "SELECT COUNT(*) FROM virtual_categories WHERE name='Archive'") { $0.int(0) }
        XCTAssertEqual(rows.first, 2, "same name under different parents must coexist")
    }

    func testOldSchemaCatalogsAreRebuiltToAllowSiblingNames() throws {
        // Recreate the historical UNIQUE(name) table inside a real encrypted
        // catalog so the v5→v6 rebuild path is exercised against SQLCipher
        // data (a plain sqlite file cannot be opened under a catalog key).
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("librarian-oldschema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("catalog.db").path
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = Data("old-catalog-key".utf8)

        let seeded = try Catalog(path: dbPath, key: key)
        // Swap the current taxonomy table back to its historical shape.
        try seeded.run("DROP TABLE category_membership")
        try seeded.run("DROP TABLE virtual_categories")
        try seeded.run("""
            CREATE TABLE virtual_categories (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                parent_id INTEGER REFERENCES virtual_categories(id) ON DELETE CASCADE
            )
            """)
        try seeded.run("INSERT INTO virtual_categories(name) VALUES ('Archive')")
        try seeded.run("""
            CREATE TABLE category_membership (
                category_id INTEGER NOT NULL REFERENCES virtual_categories(id) ON DELETE CASCADE,
                file_id TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                source TEXT NOT NULL DEFAULT 'classifier',
                PRIMARY KEY (category_id, file_id)
            )
            """)

        // Reopening must detect the old table SQL, rebuild it, and then allow
        // sibling same-name categories.
        let reopened = try Catalog(path: dbPath, key: key)
        _ = try reopened.ensureCategory(named: "Tax/Archive")
        let rows = try reopened.query(
            "SELECT COUNT(*) FROM virtual_categories WHERE name='Archive'") { $0.int(0) }
        XCTAssertEqual(rows.first, 2, "rebuild must allow sibling same-name categories")
    }

    // MARK: - Virtual tree assembly

    func testVirtualTreeKeepsNestedCategories() {
        let tree = VirtualTree.build(memberships: [
            ("School", "f1"),
            ("School/MAT-171", "f2"),
            ("School/CSC-151", "f3"),
            ("School/CSC-151/Labs", "f4"),
        ])
        XCTAssertEqual(tree.children.count, 1)
        let school = tree.children[0]
        XCTAssertEqual(school.name, "School")
        XCTAssertTrue(school.fileIDs.contains("f1"))
        XCTAssertEqual(Set(school.children.map(\.name)), Set(["CSC-151", "MAT-171"]),
                       "nested categories must survive assembly")
        let csc = school.children.first { $0.name == "CSC-151" }!
        XCTAssertTrue(csc.fileIDs.contains("f3"))
        XCTAssertEqual(csc.children.map(\.name), ["Labs"], "grandchildren must survive too")
        XCTAssertTrue(csc.children[0].fileIDs.contains("f4"))
    }

    // MARK: - Review inbox durability

    func testResolvedReviewItemStaysResolvedAfterReclassification() throws {
        let catalog = try TestSupport.makeCatalog()
        try indexTextFile(catalog, id: "review-me", path: "/tmp/review-me.txt",
                          categories: ["Documents"], confidence: 0.4)
        XCTAssertEqual(try catalog.reviewItems(limit: 10).map(\.fileID), ["review-me"])

        try catalog.applyReviewCorrection(fileID: "review-me", category: "Documents",
                                          action: .addCategory)
        XCTAssertTrue(try catalog.reviewItems(limit: 10).isEmpty, "correction resolves the item")

        // A reindex at the same low confidence must not silently reopen it.
        try catalog.saveClassification(
            Classification(fileID: "review-me", categories: ["Documents"], description: "",
                           confidence: 0.4, reasonCodes: ["test"]),
            classifier: "test")
        XCTAssertTrue(try catalog.reviewItems(limit: 10).isEmpty,
                      "resolved items must survive reclassification")
    }

    func testAddCategoryAfterMarkUnknownDropsUnknownMembership() throws {
        let catalog = try TestSupport.makeCatalog()
        try indexTextFile(catalog, id: "mystery", path: "/tmp/mystery.txt",
                          categories: [], confidence: 0.2)
        try catalog.applyReviewCorrection(fileID: "mystery", category: "", action: .markUnknown)

        func membershipPaths() throws -> Set<String> {
            Set(try catalog.categoryMemberships()
                .filter { $0.fileID == "mystery" }.map(\.categoryPath))
        }
        XCTAssertTrue(try membershipPaths().contains("Review/Unknown"))

        try catalog.applyReviewCorrection(fileID: "mystery", category: "Invoices",
                                          action: .addCategory)
        let paths = try membershipPaths()
        XCTAssertTrue(paths.contains("Invoices"))
        XCTAssertFalse(paths.contains("Review/Unknown"),
                       "an explicit correction supersedes the unknown decision")
    }

    // MARK: - Duplicate view agreement

    func testDuplicateViewsIgnoreMissingTwins() throws {
        let catalog = try TestSupport.makeCatalog()
        for id in ["twin-a", "twin-b"] {
            try indexTextFile(catalog, id: id, path: "/tmp/\(id).txt",
                              categories: ["Documents"], confidence: 0.9)
            try catalog.recordHash(fileID: id, size: 64, sha256: Data([0xAB, 0xCD]))
        }
        XCTAssertEqual(try catalog.duplicateFileIDs(), Set(["twin-a", "twin-b"]))

        try catalog.setStatus(fileID: "twin-b", status: "missing")
        XCTAssertTrue(try catalog.duplicateFileIDs().isEmpty,
                      "a copy whose twin is gone is not a duplicate")
        XCTAssertEqual(try catalog.dashboard().duplicateGroups, 0,
                       "duplicates view and dashboard must agree")
        XCTAssertTrue(try catalog.boundedFileSummaries(duplicateOnly: true).isEmpty)
    }

    // MARK: - Screenshot calibration

    func testCameraPhotoMetadataAndRatiosAreNotScreenshots() {
        let intelligence = ScreenshotIntelligence()
        // 4:3 iPhone camera photo with device-model metadata + generic OCR.
        let camera = ScreenshotImageMetadata(
            pixelWidth: 4032, pixelHeight: 3024,
            properties: ["{tiff} {model = \"apple iphone 14 pro\";}", "{profile name = display p3}"])
        let photo = intelligence.assess(filename: "IMG_4032.jpg", metadata: camera,
                                        ocrText: "birthday party everyone smiling")
        XCTAssertFalse(photo.isScreenshot, "camera photos must not classify as screenshots")

        // 16:9 camera grab with generic OCR noise: ratio alone (plus weak OCR)
        // must stay below the decision gate.
        let grab = ScreenshotImageMetadata(pixelWidth: 1920, pixelHeight: 1080, properties: [])
        let videoFrame = intelligence.assess(filename: "clip_frame.jpg", metadata: grab,
                                             ocrText: "some words visible")
        XCTAssertFalse(videoFrame.isScreenshot)

        // A real screenshot still detects: filename + screen dimensions.
        let screen = ScreenshotImageMetadata(pixelWidth: 1440, pixelHeight: 900, properties: [])
        let shot = intelligence.assess(filename: "Screenshot 2026-09-01.png", metadata: screen,
                                       ocrText: nil)
        XCTAssertTrue(shot.isScreenshot)
    }

    // MARK: - Audio container gating

    func testAudioProbeRejectsImageContainers() {
        let webp: [UInt8] = [0x52, 0x49, 0x46, 0x46] + [0x00, 0x10, 0x00, 0x00]
            + Array("WEBP".utf8) + [UInt8](repeating: 0, count: 1100)
        XCTAssertEqual(AudioProbe.probe(bytes: Data(webp)).shouldTranscribe, false,
                       "RIFF/WebP images are not audio")

        let heic: [UInt8] = [0x00, 0x00, 0x00, 0x18] + Array("ftypheic".utf8)
            + [UInt8](repeating: 0, count: 1100)
        XCTAssertEqual(AudioProbe.probe(bytes: Data(heic)).shouldTranscribe, false,
                       "HEIC image containers are not audio")

        // RIFF/WAVE stays audio.
        let wave: [UInt8] = [0x52, 0x49, 0x46, 0x46] + [0x00, 0x10, 0x00, 0x00]
            + Array("WAVE".utf8) + [UInt8](repeating: 0, count: 1100)
        XCTAssertEqual(AudioProbe.probe(bytes: Data(wave)).shouldTranscribe, true,
                       "RIFF/WAVE remains a transcribable container")
    }

    // MARK: - Text decoding

    func testDecodeTextHandlesBOMMarkedUTF16() throws {
        let text = "assignment due friday"
        let utf16LE = Data([0xFF, 0xFE]) + text.data(using: String.Encoding.utf16LittleEndian)!
        XCTAssertEqual(EvidenceExtractor.decodeText(utf16LE), text)

        let utf8 = Data("plain utf8".utf8)
        XCTAssertEqual(EvidenceExtractor.decodeText(utf8), "plain utf8")

        let latin1 = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in Latin-1
        XCTAssertEqual(EvidenceExtractor.decodeText(latin1), "caf\u{E9}")
    }

    // MARK: - Decoder configuration bounds

    func testPCMDecoderRejectsAbsurdTargetRate() throws {
        let decoder = BrokerPCMDecoder(sampleRate: 1e15)
        // Minimal valid WAV header; the configuration check must fire before
        // any allocation attempt.
        var wav = Data(Array("RIFF".utf8)) + Data([0x24, 0x00, 0x00, 0x00]) + Data(Array("WAVE".utf8))
        wav.append(Data([UInt8](repeating: 0, count: 36)))
        XCTAssertThrowsError(try decoder.decode(snapshot: wav) { _ in })
    }

    // MARK: - Provider identity

    func testUnknownProviderKindsResolveToCanonicalIdentity() {
        let canonical = LocalModelEmbeddingProvider()
        XCTAssertEqual(EmbeddingProviderFactory.make(kind: "python").providerID, canonical.providerID)
        XCTAssertEqual(EmbeddingProviderFactory.make(kind: "clip").textModelID, canonical.textModelID)
    }

    // MARK: - Hash metadata coherence

    func testRecordHashConflictUpdatesSize() throws {
        let catalog = try TestSupport.makeCatalog()
        try indexTextFile(catalog, id: "hashed", path: "/tmp/hashed.txt",
                          categories: [], confidence: 0.9)
        try catalog.recordHash(fileID: "hashed", size: 5, sha256: Data([0x01]))
        try catalog.recordHash(fileID: "hashed", size: 9, sha256: Data([0x02]))
        let rows = try catalog.query("SELECT size FROM exact_hashes WHERE file_id='hashed'") { $0.int(0) }
        XCTAssertEqual(rows.first, 9, "size must follow the newest hash")
    }
}
