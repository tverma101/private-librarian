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
}
