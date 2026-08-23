import XCTest
import CoreGraphics
import ImageIO
@testable import LibrarianCore

final class ScreenshotIntelligenceTests: XCTestCase {
    private let intelligence = ScreenshotIntelligence()
    private let screen = ScreenshotImageMetadata(pixelWidth: 1440, pixelHeight: 900,
                                                  properties: ["{display = MacBook screen}"])

    func testSyntheticFixturesCoverUsefulScreenshotSubtypes() {
        let fixtures: [(ScreenshotSubtype, String, String)] = [
            (.code, "Screenshot Code", "VSCode public static void main() { import Foundation }"),
            (.school, "Screenshot Homework", "Wake Tech homework chapter 4 worksheet"),
            (.lms, "Screenshot Blackboard", "Blackboard course content assignment"),
            (.receipt, "Screenshot Order", "Receipt subtotal tax order number shipping"),
            (.error, "Screenshot Error", "Error failed permission denied stack trace"),
            (.conversation, "Screenshot Chat", "Message sent delivered reply"),
            (.social, "Screenshot Social", "Followers following likes comments repost"),
            (.map, "Screenshot Directions", "Maps directions route 4 miles arrive"),
            (.meme, "Screenshot Meme", "Meme top text bottom text")
        ]
        for (expected, filename, text) in fixtures {
            let result = intelligence.assess(filename: filename, metadata: screen, ocrText: text)
            XCTAssertTrue(result.isScreenshot, "\(filename) should be detected")
            XCTAssertEqual(result.subtype, expected, "\(filename) subtype")
            XCTAssertTrue(result.reasonCodes.contains { $0.hasPrefix("filename:") })
            XCTAssertTrue(result.reasonCodes.contains { $0.hasPrefix("dimensions:") })
            XCTAssertTrue(result.reasonCodes.contains { $0.hasPrefix("content:") })
            XCTAssertGreaterThan(result.confidence, 0.8)
        }
    }

    func testFilenameAloneDoesNotDetectAndUncertaintyRoutesToReview() {
        let control = intelligence.assess(filename: "Screenshot.png", ocrText: nil)
        XCTAssertFalse(control.isScreenshot, "filename alone is not sufficient evidence")

        let uncertain = intelligence.assess(filename: "Screenshot.png",
                                             metadata: ScreenshotImageMetadata(pixelWidth: 1440, pixelHeight: 900),
                                             ocrText: nil)
        XCTAssertTrue(uncertain.isScreenshot)
        XCTAssertTrue(uncertain.isUncertain)
        XCTAssertTrue(uncertain.reasonCodes.contains("uncertain:review"))
    }

    func testAssessmentPersistsInEncryptedCatalog() throws {
        let catalog = try TestSupport.makeCatalog()
        let identity = FileIdentity(path: "/tmp/Screenshot.png", volumeUUID: nil, fileID: 1,
                                    size: 10, mtime: Date(), ctime: Date(), kind: .image, isSymlink: false)
        try catalog.upsertFile(identity: identity, id: "file_screenshot")
        let assessment = intelligence.assess(filename: "Screenshot.png", metadata: screen,
                                              ocrText: "Blackboard course content assignment")
        try catalog.saveScreenshotAssessment(fileID: "file_screenshot", assessment: assessment)
        let roundTrip = try catalog.screenshotAssessment(forFile: "file_screenshot")
        XCTAssertEqual(roundTrip, assessment)
        XCTAssertEqual(roundTrip?.subtype, .lms)
    }

    func testIndexerAddsVirtualScreenshotAndReviewMemberships() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("screenshot-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        try Self.writeScreenPNG(to: root.appendingPathComponent("Screenshot.png"))
        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        XCTAssertEqual(try indexer.indexRoot(root), 1)
        let file = try XCTUnwrap(try catalog.allFiles().first)
        let stored = try XCTUnwrap(try catalog.screenshotAssessment(forFile: file.id))
        XCTAssertTrue(stored.isScreenshot)
        XCTAssertEqual(stored.subtype, .reference)
        let memberships = try catalog.query("""
            SELECT c.name FROM category_membership m
            JOIN virtual_categories c ON c.id=m.category_id WHERE m.file_id=?
            """, binds: [.text(file.id)]) { $0.text(0) ?? "" }
        XCTAssertTrue(memberships.contains("Screenshots"))
        XCTAssertTrue(memberships.contains("reference"))
        XCTAssertTrue(memberships.contains("Review"))
        XCTAssertEqual(try indexer.indexRoot(root), 0, "unchanged screenshot fixture must be skipped")
    }

    private static func writeScreenPNG(to url: URL) throws {
        let width = 1440, height = 900
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}
