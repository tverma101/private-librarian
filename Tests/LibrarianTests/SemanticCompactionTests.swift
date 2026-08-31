import XCTest
@testable import LibrarianCore

final class SemanticCompactionTests: XCTestCase {
    func testLargeSourceGetsOneBoundedCapsule() {
        let body = (0..<2_000).map { index in
            index.isMultiple(of: 100)
                ? "func feature\(index)() { print(\(index)) }"
                : "let generatedValue\(index) = \(index)"
        }.joined(separator: "\n")

        let strategy = SemanticCompaction.strategy(path: "/repo/src/browser/Engine.swift", text: body)
        guard case .single(let capsule) = strategy else {
            return XCTFail("authored source should produce one semantic capsule")
        }
        XCTAssertLessThanOrEqual(capsule.count, SemanticCompaction.maxPrimaryCharacters)
        XCTAssertTrue(capsule.contains("Engine.swift"))
        XCTAssertTrue(capsule.contains("func feature"))
    }

    func testLockfilesSourceMapsAndMinifiedBundlesSkipEmbeddings() {
        for path in [
            "/repo/package-lock.json",
            "/repo/pnpm-lock.yaml",
            "/repo/yarn.lock",
            "/repo/dist/app.js.map",
            "/repo/public/app.min.js",
            "/repo/public/site.min.css"
        ] {
            XCTAssertEqual(SemanticCompaction.strategy(path: path, text: "lots of machine output"), .skip, path)
        }
    }

    func testLongProseKeepsPrimaryAndCapsChunkFanout() {
        let prose = Array(repeating: "A useful paragraph about biology, coursework, and lecture notes.", count: 500)
            .joined(separator: " ")
        let strategy = SemanticCompaction.strategy(path: "/notes/biology.md", text: prose)
        guard case .prose(let primary, let chunks) = strategy else {
            return XCTFail("prose should remain chunk-searchable")
        }
        XCTAssertLessThanOrEqual(primary.count, SemanticCompaction.maxPrimaryCharacters)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertLessThanOrEqual(chunks.count, SemanticCompaction.maxProseChunks)
    }
}
