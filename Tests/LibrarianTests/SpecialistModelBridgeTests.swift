import Foundation
import XCTest
@testable import LibrarianCore

final class SpecialistModelBridgeTests: XCTestCase {
    func testConfiguredSpecialistRootIsResolvedDirectly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-librarian-specialists-\(UUID().uuidString)", isDirectory: true)
        let modelRoot = root.appendingPathComponent(LocalModelStack.siglip2.id, isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = modelRoot.appendingPathComponent("weights.bin")
        try Data("fixture checkpoint".utf8).write(to: payload)
        let manifest: [String: Any] = [
            "schema": 1,
            "model": LocalModelStack.siglip2.id,
            "hf_id": LocalModelStack.siglip2.hfID,
            "revision": LocalModelStack.siglip2.revisionPrefix + String(repeating: "0", count: 33),
            "license": LocalModelStack.siglip2.license,
            "expected_files": ["weights.bin": String(repeating: "a", count: 64)],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: modelRoot.appendingPathComponent("provenance.json"))

        XCTAssertTrue(
            SpecialistModelBridge.isProvisioned(LocalModelStack.siglip2, roots: [root]),
            "a configured .../Models/specialists root must not be treated as a Models parent"
        )
    }

    func testStructuralCheckRejectsRegularFilesOutsideManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-librarian-specialists-\(UUID().uuidString)", isDirectory: true)
        let modelRoot = root.appendingPathComponent(LocalModelStack.siglip2.id, isDirectory: true)
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("fixture checkpoint".utf8).write(to: modelRoot.appendingPathComponent("weights.bin"))
        try Data("unexpected".utf8).write(to: modelRoot.appendingPathComponent("unexpected.bin"))
        let manifest: [String: Any] = [
            "schema": 1,
            "model": LocalModelStack.siglip2.id,
            "hf_id": LocalModelStack.siglip2.hfID,
            "revision": LocalModelStack.siglip2.revisionPrefix + String(repeating: "0", count: 33),
            "expected_files": ["weights.bin": String(repeating: "a", count: 64)],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: modelRoot.appendingPathComponent("provenance.json"))

        XCTAssertFalse(SpecialistModelBridge.isProvisioned(LocalModelStack.siglip2, roots: [root]))
    }

    #if os(macOS)
    func testPaddleOCRIsReportedUnsupportedOnMacOS() {
        let preflight = SpecialistModelBridge.preflight(LocalModelStack.paddleOCR)
        XCTAssertFalse(preflight.available)
        XCTAssertTrue(preflight.reason.localizedCaseInsensitiveContains("not supported"))
    }
    #endif

}
