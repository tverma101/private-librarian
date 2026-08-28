import XCTest
@testable import LibrarianCore

/// Exercises the real Indexer → EmbeddingProvider → encrypted catalog →
/// SearchService seam without depending on optional downloaded model artifacts.
final class Tier2IntegrationTests: XCTestCase {
    private struct FixtureProvider: EmbeddingProvider {
        let providerID = "fixture-tier2-v1"
        let imageModelID = "image:fixture-tier2-v1"
        let textModelID = "text:fixture-tier2-v1"

        var preflight: EmbeddingProviderPreflight {
            EmbeddingProviderPreflight(
                providerID: providerID,
                available: true,
                reason: "Deterministic test provider",
                artifacts: ["in-memory-fixture"],
                dependencies: [])
        }

        func embedText(_ text: String) -> EmbeddingVector? {
            guard !text.isEmpty else { return nil }
            return EmbeddingVector(spaceID: textModelID, dim: 3, data: Self.vector([1, 0, 0]))
        }

        func embedImageBytes(_ bytes: Data) -> EmbeddingVector? { nil }

        func embedJointText(_ text: String) -> EmbeddingVector? { nil }

        private static func vector(_ values: [Float]) -> Data {
            var data = Data(capacity: values.count * MemoryLayout<Float>.stride)
            for var value in values {
                withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
            }
            return data
        }
    }

    func testInjectedProviderIndexesAndSearchesWithoutSourceMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tier2-integration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt")
        try "CSC-151 integration fixture".write(to: source, atomically: true, encoding: .utf8)

        let before = try TestSupport.snapshot(root: root)
        let catalog = try TestSupport.makeCatalog()
        var options = Indexer.Options()
        options.enableLocalEmbeddings = true
        options.enableOCR = false
        let provider = FixtureProvider()
        let indexer = Indexer(
            broker: SourceBroker(),
            catalog: catalog,
            scheduler: Scheduler(),
            options: options,
            embeddingProvider: provider)

        XCTAssertEqual(try indexer.indexRoot(root), 1)
        let stored = try catalog.query(
            "SELECT model, dim FROM embeddings WHERE model=?",
            binds: [.text(provider.textModelID)]) { ($0.text(0) ?? "", $0.int(1)) }
        XCTAssertEqual(stored.first?.0, provider.textModelID)
        XCTAssertEqual(stored.first?.1, 3)
        XCTAssertEqual(indexer.workMetrics.textEmbedCalls, 1)
        let counts = try catalog.counts()
        XCTAssertEqual(counts["embedding_rows"], 1)
        XCTAssertEqual(counts["embedding_bytes"], 12)

        let search = SearchService(
            catalog: catalog,
            enableLocalEmbeddings: true,
            embeddingProvider: provider)
        let hits = try search.semanticSearch(query: "find the integration fixture", threshold: 0.9)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, source.path)

        indexer.resetWorkMetrics()
        XCTAssertEqual(try indexer.indexRoot(root), 0)
        XCTAssertEqual(indexer.workMetrics, Indexer.WorkMetrics())
        XCTAssertEqual(try TestSupport.snapshot(root: root), before)
    }
}
