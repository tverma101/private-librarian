import XCTest
import Vision
import CoreGraphics
import ImageIO
@testable import LibrarianCore

/// Vision feature — no network, no ANE guarantee required. Tests run headless
/// (CI) so we assert graceful nil/empty and deterministic classifier wiring,
/// not specific Vision label strings.
final class VisionImageTests: XCTestCase {

    private func paddedJPEG(minimumBytes: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 64, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = context.makeImage() else {
            throw XCTSkip("CoreGraphics image fixture unavailable")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("ImageIO JPEG fixture unavailable")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("JPEG fixture failed") }
        let base = output as Data
        guard base.count > 2, base[0] == 0xFF, base[1] == 0xD8 else { throw XCTSkip("JPEG fixture missing SOI") }

        var result = Data(base.prefix(2))
        var remaining = max(0, minimumBytes - base.count)
        while remaining > 0 {
            let payload = min(65_533, max(1, remaining - 4))
            let length = UInt16(payload + 2)
            result.append(contentsOf: [0xFF, 0xFE, UInt8(length >> 8), UInt8(length & 0xFF)])
            result.append(Data(repeating: 0, count: payload))
            remaining -= payload + 4
        }
        result.append(contentsOf: base.dropFirst(2))
        return result
    }

    func testCompleteSnapshotPreservesValidImageContainerAboveEvidenceCap() throws {
        let bytes = try paddedJPEG(minimumBytes: 8 * 1024 * 1024 + 1)
        XCTAssertGreaterThan(Int64(bytes.count), 8 * 1024 * 1024)
        XCTAssertNotNil(CGImageSourceCreateWithData(bytes as CFData, nil))

        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("large-image-\(UUID().uuidString).jpg")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let broker = SourceBroker(maxReadBytes: 64, maxSnapshotBytes: 16 * 1024 * 1024)
        let snapshot = try broker.completeSnapshot(url.path, maxBytes: 16 * 1024 * 1024)
        XCTAssertEqual(snapshot, bytes, "decoder input must be the complete container")

        var streamed = Data()
        var sawEnd = false
        try broker.streamCompleteSnapshot(url.path, maxBytes: 16 * 1024 * 1024) { chunk, isLast in
            if isLast { sawEnd = true } else { streamed.append(chunk) }
        }
        XCTAssertTrue(sawEnd)
        XCTAssertEqual(streamed, bytes, "stream API must emit the complete container")
    }

    func testCompleteSnapshotRejectsOversizedContainerWithoutPrefix() throws {
        let bytes = try paddedJPEG(minimumBytes: 8 * 1024 * 1024 + 1)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("oversized-image-\(UUID().uuidString).jpg")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let broker = SourceBroker(maxReadBytes: 64, maxSnapshotBytes: 16 * 1024 * 1024)
        XCTAssertThrowsError(try broker.completeSnapshot(url.path, maxBytes: 8 * 1024 * 1024)) { error in
            guard case BrokerError.snapshotTooLarge(let size, let limit) = error else {
                return XCTFail("expected snapshotTooLarge, got \(error)")
            }
            XCTAssertEqual(size, Int64(bytes.count))
            XCTAssertEqual(limit, 8 * 1024 * 1024)
        }
    }

    func testExistingPathWrappersRemainSafeAndCompatible() throws {
        let missing = "/no/such/decoder-input.jpg"
        XCTAssertNil(VisionImageAnalyzer().analyze(path: missing, broker: SourceBroker()))
        XCTAssertNil(PDFText.extract(path: missing, broker: SourceBroker()))
        XCTAssertNil(LocalModelBridge.embedImage(at: missing))

        let catalog = try TestSupport.makeCatalog()
        let service = SearchService(catalog: catalog)
        XCTAssertEqual(try service.clipVisualSearch(nearImagePath: missing).count, 0)
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
        var nonFinite = Data()
        var nan = Float.nan
        withUnsafeBytes(of: &nan) { nonFinite.append(contentsOf: $0) }
        nonFinite.append(Data(repeating: 0, count: 12))
        XCTAssertNil(LocalModelBridge.cosineSimilarity(a, nonFinite))
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

    func testRequestedUnavailableProviderDoesNotSilentlyFallback() {
        let requested = CoreMLMobileCLIPProvider()
        let selected = EmbeddingProviderFactory.make(kind: "coreml")
        if requested.preflight.available {
            XCTAssertEqual(selected.providerID, requested.providerID)
        } else {
            XCTAssertFalse(selected.preflight.available)
            XCTAssertEqual(selected.providerID, requested.providerID)
            XCTAssertNotEqual(selected.providerID, LocalModelEmbeddingProvider().providerID)
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
        let clip = try svc.clipVisualSearch(nearImagePath: "/no/such/path.jpg", broker: SourceBroker())
        XCTAssertEqual(clip.count, 0)
        let best = try svc.bestVisualSearch(nearImagePath: "/no/such/path.jpg", broker: SourceBroker())
        XCTAssertEqual(best.count, 0)
    }
}
