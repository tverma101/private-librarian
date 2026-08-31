import XCTest
import Vision
import PDFKit
import CoreGraphics
import ImageIO
@testable import LibrarianCore

final class OCRVisionTests: XCTestCase {

    private func paddedJPEG(minimumBytes: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: 64, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw XCTSkip("CoreGraphics image fixture unavailable")
        }
        context.setFillColor(CGColor(gray: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage() else { throw XCTSkip("image fixture unavailable") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
            throw XCTSkip("ImageIO JPEG fixture unavailable")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("JPEG fixture failed") }
        let base = output as Data
        guard base.count > 2, base[0] == 0xFF, base[1] == 0xD8 else { throw XCTSkip("JPEG fixture missing SOI") }

        var padded = Data(base.prefix(2))
        var remaining = max(0, minimumBytes - base.count)
        while remaining > 0 {
            let payload = min(65_533, max(1, remaining - 4))
            let segmentLength = UInt16(payload + 2)
            padded.append(contentsOf: [0xFF, 0xFE,
                                        UInt8(segmentLength >> 8), UInt8(segmentLength & 0xFF)])
            padded.append(Data(repeating: 0, count: payload))
            remaining -= payload + 4
        }
        padded.append(contentsOf: base.dropFirst(2))
        return padded
    }

    private func paddedPDF(minimumBytes: Int) throws -> Data {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        guard let base = document.dataRepresentation() else { throw XCTSkip("PDF fixture unavailable") }
        var result = base
        result.append(Data("\n".utf8))
        if result.count < minimumBytes {
            result.append(Data(repeating: 0x20, count: minimumBytes - result.count))
        }
        return result
    }

    func testCompleteSnapshotNeverReturnsAContainerPrefix() throws {
        let broker = SourceBroker(maxReadBytes: 64, maxSnapshotBytes: 2 * 1024 * 1024)
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapshot-\(UUID().uuidString).pdf")
        let bytes = Data(repeating: 0x5A, count: 256 * 1024)
        try bytes.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        XCTAssertEqual(try broker.completeSnapshot(tmp.path), bytes)
        XCTAssertThrowsError(try broker.completeSnapshot(tmp.path, maxBytes: 128 * 1024))
    }

    func testOversizedImageContainerIsCompleteAboveVisionEvidenceCap() throws {
        let oldEvidenceCap: Int64 = 8 * 1024 * 1024
        let bytes = try paddedJPEG(minimumBytes: Int(oldEvidenceCap) + 1)
        XCTAssertGreaterThan(Int64(bytes.count), oldEvidenceCap)
        XCTAssertNotNil(CGImageSourceCreateWithData(bytes as CFData, nil))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("large-image-\(UUID().uuidString).jpg")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let broker = SourceBroker(maxReadBytes: 64, maxSnapshotBytes: Int64(VisionOCR.maxImageBytes))
        let snapshot = try broker.completeSnapshot(url.path, maxBytes: Int64(VisionOCR.maxImageBytes))
        XCTAssertEqual(snapshot, bytes, "OCR must receive a complete image container, not the old 8 MiB prefix")
    }

    func testOversizedPDFContainerIsCompleteAndNotPrefixDecoded() throws {
        let bytes = try paddedPDF(minimumBytes: 20 * 1024 * 1024 + 1)
        XCTAssertGreaterThan(bytes.count, 20 * 1024 * 1024)
        XCTAssertNotNil(PDFDocument(data: bytes))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("large-pdf-\(UUID().uuidString).pdf")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let broker = SourceBroker(maxReadBytes: 64, maxSnapshotBytes: 256 * 1024 * 1024)
        let snapshot = try broker.completeSnapshot(url.path)
        XCTAssertEqual(snapshot, bytes, "PDF parsing must use the complete broker snapshot")
    }

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
