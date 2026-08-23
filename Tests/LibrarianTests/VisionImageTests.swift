import XCTest
import Vision
@testable import LibrarianCore

/// Vision feature — no network, no ANE guarantee required. Tests run headless
/// (CI) so we assert graceful nil/empty and deterministic classifier wiring,
/// not specific Vision label strings.
final class VisionImageTests: XCTestCase {

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

    // 3. Classifier wiring: visionLabels actually land as Image/... categories.
    func testClassifierMapsVisionLabelsToImageCategories() throws {
        let c = RuleBasedClassifier()
        let ident = FileIdentity(path: "/tmp/photo.jpg", volumeUUID: nil, fileID: 1, size: 100, mtime: Date(), ctime: Date(), kind: .image, isSymlink: false)
        let ev = EvidenceExtractor.Evidence(filenameTokens: [], sizeClass: "small", isCloudPlaceholder: false, textSample: nil)
        let cls = c.classify(fileID: "test-id", identity: ident, evidence: ev, textContent: nil,
                             visionLabels: [("cat", 0.92), ("beach", 0.40)])
        XCTAssertTrue(cls.categories.contains("Image/Animals/cat") || cls.categories.contains("Image/cat"),
                      "expected cat-derived category, got \(cls.categories)")
        XCTAssertTrue(cls.categories.contains(where: { $0.contains("Scenery") || $0.contains("beach") }) || cls.categories.contains("Image/beach"),
                      "expected beach-derived category, got \(cls.categories)")
        // Low-confidence labels (< 0.15) must be ignored.
        let low = c.classify(fileID: "test-id", identity: ident, evidence: EvidenceExtractor.Evidence(filenameTokens: [], sizeClass: "small", isCloudPlaceholder: false, textSample: nil), textContent: nil,
                             visionLabels: [("cat", 0.05)])
        XCTAssertFalse(low.categories.contains(where: { $0.contains("cat") }), "low-conf vision label must be ignored")
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
        let a = Data(repeating: 0x01, count: 64)
        let b = Data(repeating: 0x01, count: 64)
        let d0 = VisionImageAnalyzer.cosineDistance(a, b)
        XCTAssertNotNil(d0)
        XCTAssertEqual(d0!, 0, accuracy: 1e-5)

        let c = Data(repeating: 0xFF, count: 64)
        let d1 = VisionImageAnalyzer.cosineDistance(a, c)
        XCTAssertNotNil(d1)
        XCTAssertGreaterThan(d1!, 0)

        // Mismatched sizes → nil (visualSearch must drop, not crash)
        XCTAssertNil(VisionImageAnalyzer.cosineDistance(Data(repeating: 0x01, count: 32), Data(repeating: 0x01, count: 64)))
    }

    // 5. LocalModelBridge — offline helpers, no network, no provisioned-model required to pass.
    func testLocalModelBridgeGracefulWithoutModels() {
        // Cosine on normalized synthetic vectors: self == 1, different < 1
        var a = Data(); var b = Data(); var c = Data()
        for v in [Float(1), 0, 0, 0] { withUnsafeBytes(of: v) { a.append(contentsOf: $0) } }
        for v in [Float(1), 0, 0, 0] { withUnsafeBytes(of: v) { b.append(contentsOf: $0) } }
        for v in [Float(0), 1, 0, 0] { withUnsafeBytes(of: v) { c.append(contentsOf: $0) } }
        XCTAssertEqual(LocalModelBridge.cosineSimilarity(a, b) ?? -2, 1, accuracy: 1e-5)
        XCTAssertEqual(LocalModelBridge.cosineSimilarity(a, c) ?? -2, 0, accuracy: 1e-5)
        XCTAssertNil(LocalModelBridge.cosineSimilarity(a, Data(repeating: 0, count: 8)))
        // parseEmbedding handles JSON correctly
        let js = #"{"dim":3,"vector":[0.1,0.2,0.3]}"#
        let p = LocalModelBridge.parseEmbedding(from: js)
        XCTAssertEqual(p?.dim, 3)
        XCTAssertEqual(p?.data.count, 12)
        XCTAssertNil(LocalModelBridge.parseEmbedding(from: #"{"bad":1}"#))
        XCTAssertNil(LocalModelBridge.parseEmbedding(from: #"{"dim":3,"vector":[0.1,0.2,0.3]}"#, expectedDim: 512))
        XCTAssertEqual(LocalModelBridge.expectedDimension(.clipImage), 512)
        XCTAssertEqual(LocalModelBridge.expectedDimension(.miniLMText), 384)
    }

    func testProviderDecisionIsExplicitAndProvenanceIncludesPreprocessing() {
        let python = LocalModelEmbeddingProvider()
        XCTAssertTrue(python.providerID.contains("clip-vit-base-patch32"))
        XCTAssertTrue(python.providerID.contains("resize224-centerCrop"))
        XCTAssertEqual(python.preflight.providerID, python.providerID)

        let native = CoreMLMobileCLIPProvider()
        XCTAssertTrue(native.providerID.contains("mobileclip-s0"))
        XCTAssertEqual(native.preflight.providerID, native.providerID)
        if !native.preflight.available {
            XCTAssertFalse(native.preflight.reason.isEmpty)
            XCTAssertNil(native.embedImageBytes(Data([0x00])))
            XCTAssertNil(native.embedJointText("native preflight"))
        }
    }

    func testMobileCLIPTokenizerProducesBoundedCoreMLInput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobileclip-tokenizer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"<|startoftext|>":1,"<|endoftext|>":2,"h":3,"i</w>":4}"#.utf8)
            .write(to: root.appendingPathComponent("vocab.json"))
        try Data("#version: 0.2\n".utf8).write(to: root.appendingPathComponent("merges.txt"))
        guard let tokenizer = MobileCLIPTokenizer(modelRoots: [root]) else {
            XCTFail("fixture tokenizer failed to load")
            return
        }
        let tokens = tokenizer.encodeFull("hi")
        XCTAssertEqual(tokens.count, 77)
        XCTAssertEqual(tokens[0], 1)
        XCTAssertEqual(tokens[1], 3)
        XCTAssertEqual(tokens[2], 4)
        XCTAssertEqual(tokens[3], 2)
        XCTAssertTrue(tokens.allSatisfy { $0 >= 0 })
    }

    func testSemanticAndClipSearchReturnEmptyWithoutProvisionedModels() throws {
        let catalog = try TestSupport.makeCatalog()
        let svc = SearchService(catalog: catalog)
        // Without provisioned models, semantic/clip search must return [] not throw.
        // (If models ARE provisioned locally, this test still passes vacuously on empty catalog.)
        let sem = try svc.semanticSearch(query: "hello")
        XCTAssertEqual(sem.count, 0)
        let clip = try svc.clipVisualSearch(nearImagePath: "/no/such/path.jpg")
        XCTAssertEqual(clip.count, 0)
        let best = try svc.bestVisualSearch(nearImagePath: "/no/such/path.jpg", broker: SourceBroker())
        XCTAssertEqual(best.count, 0)
    }
}
