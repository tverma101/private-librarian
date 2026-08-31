import XCTest
import CoreGraphics
import ImageIO
@testable import LibrarianCore

final class ImageJunkScorerTests: XCTestCase {
    func testTinyBlankImageIsLikelyJunk() throws {
        let data = try png(width: 48, height: 48) { _, _ in 250 }
        let result = ImageJunkScorer.assess(data: data, ocrText: nil)
        XCTAssertTrue(result.isLikelyJunk)
        XCTAssertGreaterThanOrEqual(result.score, ImageJunkScorer.threshold)
        XCTAssertTrue(result.reasons.contains("near-blank"))
    }

    func testUsefulOCRHardVetoesJunk() throws {
        let data = try png(width: 48, height: 48) { _, _ in 250 }
        let result = ImageJunkScorer.assess(
            data: data,
            ocrText: "MAT-171 Exam Review: quadratic functions and polynomial equations")
        XCTAssertFalse(result.isLikelyJunk)
        XCTAssertEqual(result.reasons, ["useful-text"])
    }

    func testUsefulVisionEvidenceHardVetoesJunk() throws {
        let data = try png(width: 48, height: 48) { _, _ in 250 }
        let result = ImageJunkScorer.assess(
            data: data,
            ocrText: nil,
            visionLabels: [("person, portrait", 0.84)])
        XCTAssertFalse(result.isLikelyJunk)
        XCTAssertEqual(result.reasons, ["useful-visual-content"])
    }

    func testSmallButInformationRichImageIsNotJunk() throws {
        let data = try png(width: 256, height: 256) { x, y in
            UInt8((x * 17 + y * 29) % 256)
        }
        let result = ImageJunkScorer.assess(data: data, ocrText: nil)
        XCTAssertFalse(result.isLikelyJunk)
        XCTAssertFalse(result.reasons.contains("near-blank"))
    }

    func testBlankScreenshotStillRequiresObjectiveJunkEvidence() throws {
        let data = try png(width: 160, height: 40) { _, _ in 0 }
        let result = ImageJunkScorer.assess(
            data: data,
            ocrText: nil,
            isScreenshot: true)
        XCTAssertTrue(result.isLikelyJunk)
        XCTAssertTrue(result.reasons.contains("near-blank"))
    }

    private func png(width: Int, height: Int, value: (Int, Int) -> UInt8) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = value(x, y)
            }
        }

        let image: CGImage = try pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let image = context.makeImage() else {
                throw NSError(domain: "ImageJunkScorerTests", code: 1)
            }
            return image
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.png" as CFString, 1, nil) else {
            throw NSError(domain: "ImageJunkScorerTests", code: 2)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "ImageJunkScorerTests", code: 3)
        }
        return output as Data
    }
}
