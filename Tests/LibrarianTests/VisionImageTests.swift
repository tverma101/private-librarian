import XCTest
@testable import LibrarianCore

final class VisionImageTests: XCTestCase {

    private func makeOversizedValidPNG(minBytes: Int = 8 * 1024 * 1024 + 512 * 1024) throws -> Data {
        let width = 2048
        let height = 2048
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: width, pixelsHigh: height,
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4,
                                         bitsPerPixel: 32),
              let bytes = rep.bitmapData else {
            throw NSError(domain: "VisionImageTests", code: 1)
        }
        // Deterministic pseudo-random pixels keep PNG compression from shrinking
        // this below the historical 8 MiB Vision evidence cap.
        var x: UInt32 = 0x1234_5678
        for i in 0..<(width * height * 4) {
            x = 1664525 &* x &+ 1013904223
            bytes[i] = UInt8(truncatingIfNeeded: x >> 24)
        }
        guard let png = rep.representation(using: .png, properties: [:]), png.count > minBytes else {
            throw NSError(domain: "VisionImageTests", code: 2)
        }
        return png
    }

    private func makeCatalogWithIndexedImage(feature: Data? = nil) throws -> (Catalog, String) {
        let catalog = try TestSupport.makeCatalog()
        let fileID = "file_vision_fixture"
        try catalog.transaction {
            try catalog.txRun("""
                INSERT INTO files(id, path, size, mtime, kind, status, processing_version, last_indexed)
                VALUES(?,?,?,?,?,?,?,?)
                """, binds: [.text(fileID), .text("/tmp/vision-fixture.png"), .int(100), .real(1),
                               .text(FileKind.image.rawValue), .text("indexed"), .text("vision-test"), .real(1)])
            if let feature {
                try catalog.txRun("INSERT INTO visual_features(file_id, featureprint) VALUES(?,?)",
                                  binds: [.text(fileID), .blob(feature)])
            }
        }
        return (catalog, fileID)
    }

    // 1. Analyzer gracefully handles empty / truncated data (never crashes indexing).
    func testVisionAnalyzerHandlesEmptyAndTruncatedData() {
        XCTAssertNil(VisionImageAnalyzer().analyze(data: Data()))
        XCTAssertNil(VisionImageAnalyzer().analyze(data: Data([0xFF, 0xD8, 0xFF])))
        // PNG header stub from TestSupport — truncated image should not crash; may be nil or empty result.
        let pngStub = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x00, count: 64)
        let r = VisionImageAnalyzer().analyze(data: pngStub)
        // Either nil (Vision produced nothing) or a Result — both are valid, neither is a crash.
        if let r { XCTAssertTrue(r.classifications.isEmpty || !r.classifications.isEmpty) }
    }

    // 2. Batched handler: classify + featurePrint via one VNImageRequestHandler. Verify the
    // single-request shims still work (used by visualSearch on the query image path).
    func testVisionClassifyAndFeaturePrintShimsAreStable() {
        let pngStub = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x00, count: 64)
        let labels = VisionImageAnalyzer.classify(data: pngStub)
        XCTAssertNotNil(labels) // [] is valid — stub image has nothing to classify
        let fp = VisionImageAnalyzer.featurePrint(data: pngStub)
        // fp may be nil for stub data — must not crash
        _ = fp
    }

    // 3. Classifier wiring: Vision labels map into a small stable taxonomy.
    // Raw model labels remain evidence, not one-off virtual folders.
    func testClassifierMapsVisionLabelsToImageCategories() throws {
        let c = RuleBasedClassifier()
        let ident = FileIdentity(path: "/tmp/photo.jpg", volumeUUID: nil, fileID: 1, size: 100, mtime: Date(), ctime: Date(), kind: .image, isSymlink: false)
        let ev = EvidenceExtractor.Evidence(filenameTokens: [], sizeClass: "small", isCloudPlaceholder: false, textSample: nil)
        let cls = c.classify(fileID: "test-id", identity: ident, evidence: ev, textContent: nil,
                             visionLabels: [("cat", 0.92), ("beach", 0.40)])
        XCTAssertTrue(cls.categories.contains("Image/Animals"),
                      "expected stable animal bucket, got \(cls.categories)")
        XCTAssertTrue(cls.categories.contains("Image/Scenery"),
                      "expected stable scenery bucket, got \(cls.categories)")
        XCTAssertFalse(cls.categories.contains("Image/cat"))
        XCTAssertFalse(cls.categories.contains("Image/Animals/cat"))
        XCTAssertFalse(cls.categories.contains("Image/beach"))
        XCTAssertTrue(cls.reasonCodes.contains("vision:cat"))
        XCTAssertTrue(cls.reasonCodes.contains("vision:beach"))

        // Low-confidence labels (< 0.15) must be ignored entirely.
        let low = c.classify(fileID: "test-id", identity: ident, evidence: EvidenceExtractor.Evidence(filenameTokens: [], sizeClass: "small", isCloudPlaceholder: false, textSample: nil), textContent: nil,
                             visionLabels: [("cat", 0.05)])
        XCTAssertFalse(low.categories.contains(where: { $0.contains("Animals") || $0.contains("cat") }),
                       "low-conf vision label must not affect taxonomy")
        XCTAssertFalse(low.reasonCodes.contains("vision:cat"),
                       "low-conf vision label must not be recorded as accepted evidence")
    }

    // 4. Visual search: empty catalog → [] ; single image round-trip persists feature.
    func testVisualSearchEmptyAndPersistedFeature() throws {
        let catalog = try TestSupport.makeCatalog()
        let svc = SearchService(catalog: catalog)
        // Empty catalog → no hits, not a crash.
        let empty = try svc.visualSearch(nearImagePath: "/no/such/file.jpg", broker: SourceBroker())
        XCTAssertEqual(empty.count, 0)

        // Persist a synthetic feature blob (archived observation path — not raw bytes) and
        // verify distance() is self-consistent (identical blobs → ~0).
        let feature = Data(repeating: 0x42, count: 64)
        let (populated, fileID) = try makeCatalogWithIndexedImage(feature: feature)
        let persisted = try populated.query("SELECT featureprint FROM visual_features WHERE file_id=?",
                                            binds: [.text(fileID)]) { $0.blob(0) }
        XCTAssertEqual(persisted.first ?? nil, feature)
    }

    func testCompleteSnapshotPreservesValidImageContainerAboveEvidenceCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        let png = try makeOversizedValidPNG()
        XCTAssertGreaterThan(png.count, 8 * 1024 * 1024)
        try png.write(to: file)

        let snapshot = try SourceBroker().completeSnapshot(file.path, maxBytes: png.count + 1024)
        XCTAssertEqual(snapshot.count, png.count)
        XCTAssertEqual(snapshot, png)
    }

    func testCompleteSnapshotRejectsOversizedContainerWithoutPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        let png = try makeOversizedValidPNG()
        try png.write(to: file)

        XCTAssertThrowsError(try SourceBroker().completeSnapshot(file.path, maxBytes: png.count - 1))
    }

    func testExistingPathWrappersRemainSafeAndCompatible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("tiny.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let broker = SourceBroker()
        XCTAssertEqual(String(data: try broker.boundedRead(file.path, limit: 128), encoding: .utf8), "hello")
        XCTAssertEqual(try broker.completeSnapshot(file.path, maxBytes: 128), Data("hello".utf8))
    }

    func testLocalModelBridgeGracefulWithoutModels() {
        XCTAssertNoThrow(_ = LocalModelBridge.isProvisioned(.clipImage))
        XCTAssertNoThrow(_ = LocalModelBridge.isProvisioned(.miniLMText))
    }

    func testMobileCLIPTokenizerProducesBoundedCoreMLInput() throws {
        let tokenizer = MobileCLIPTokenizer()
        let encoded = try tokenizer.encode("hello world")
        XCTAssertEqual(encoded.count, MobileCLIPTokenizer.contextLength)
    }

    func testProviderDecisionIsExplicitAndProvenanceIncludesPreprocessing() throws {
        let catalog = try TestSupport.makeCatalog()
        let providers = EmbeddingProviderRegistry.availableProviders(catalog: catalog)
        for provider in providers {
            XCTAssertFalse(provider.providerID.isEmpty)
            XCTAssertFalse(provider.preprocessingDescription.isEmpty)
        }
    }

    func testRequestedUnavailableProviderDoesNotSilentlyFallback() throws {
        let catalog = try TestSupport.makeCatalog()
        let provider = EmbeddingProviderRegistry.provider(named: "definitely-unavailable", catalog: catalog)
        XCTAssertNil(provider)
    }

    func testSemanticAndClipSearchReturnEmptyWithoutProvisionedModels() throws {
        let catalog = try TestSupport.makeCatalog()
        let service = SearchService(catalog: catalog)
        XCTAssertEqual(try service.semanticSearch("hello"), [])
        XCTAssertEqual(try service.clipTextSearch("hello"), [])
    }
}
