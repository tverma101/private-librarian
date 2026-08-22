import XCTest
import Vision
@testable import LibrarianCore

final class OCRVisionTests: XCTestCase {

    func testMalformedBytesReturnNil() {
        let ocr = VisionOCR()
        XCTAssertNil(ocr.recognize(imageData: Data()))
        XCTAssertNil(ocr.recognize(imageData: Data([0x00, 0x01, 0x02, 0x03])))
        XCTAssertNil(ocr.recognize(imageData: Data([0xFF, 0xD8, 0xFF, 0xE0])))
        XCTAssertNil(ocr.recognize(imageData: Data(repeating: 0x00, count: 64)))
        // needsOCR contract
        XCTAssertTrue(VisionOCR.needsOCR(pdfText: nil))
        XCTAssertTrue(VisionOCR.needsOCR(pdfText: ""))
        XCTAssertTrue(VisionOCR.needsOCR(pdfText: "   "))
        XCTAssertTrue(VisionOCR.needsOCR(pdfText: "short"))
        XCTAssertFalse(VisionOCR.needsOCR(pdfText: String(repeating: "a", count: 50)))
        XCTAssertFalse(VisionOCR.needsOCR(pdfText: String(repeating: "hello world ", count: 10)))
    }

    func testValidFlowDoesNotCrash() throws {
        let ocr = VisionOCR()
        // maxImageBytes guard visible
        XCTAssertEqual(VisionOCR.maxImageBytes, 20 * 1024 * 1024)
        // revision embedded
        XCTAssertEqual(VisionOCR.revision, "vision-ocr-v1")
        // PNG stub — truncated but must not crash; nil or result both valid
        let pngStub = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x00, count: 64)
        _ = ocr.recognize(imageData: pngStub)

        // Scanned PDF path with malformed/truncated PDF bytes — must return nil not crash
        let broker = SourceBroker()
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ocr-test-\(UUID().uuidString).pdf")
        try Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let r = ocr.recognizeScannedPDF(at: tmp.path, broker: broker, pdfText: nil)
        XCTAssertNil(r)
        // When pdfText is sufficient, needsOCR is false so scanned path is skipped
        let r2 = ocr.recognizeScannedPDF(at: tmp.path, broker: broker, pdfText: String(repeating: "sufficient text content that exceeds threshold ", count: 5))
        XCTAssertNil(r2)

        // Indexer wiring: enableOCR true includes ocr revision in processingVersion,
        // incremental skip still works (second indexOne is a skip).
        var opts = Indexer.Options()
        opts.enableOCR = true
        let catalog = try TestSupport.makeCatalog()
        let scheduler = Scheduler()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: scheduler, options: opts)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ocr-idx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "hello world for ocr wiring".write(to: file, atomically: true, encoding: .utf8)
        let first = try indexer.indexOne(path: file.path)
        XCTAssertTrue(first)
        let second = try indexer.indexOne(path: file.path)
        XCTAssertFalse(second, "incremental skip must still work with OCR enabled")
    }
}
