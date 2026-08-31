import XCTest
@testable import LibrarianCore

/// Exercises the real Indexer → EmbeddingProvider → encrypted catalog →
/// SearchService seam without depending on optional downloaded model artifacts.
final class Tier2IntegrationTests: XCTestCase {
    private final class TextRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []

        func append(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }

        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private struct FixtureProvider: EmbeddingProvider {
        let providerID = "fixture-tier2-v1"
        let imageModelID = "image:fixture-tier2-v1"
        let textModelID = "text:fixture-tier2-v1"
        let recorder: TextRecorder?

        init(recorder: TextRecorder? = nil) {
            self.recorder = recorder
        }

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
            recorder?.append(text)
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

    func testSemanticCompactionBoundsFanoutAndSkipsGeneratedOutput() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tier2-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Engine.swift")
        let lockfile = root.appendingPathComponent("package-lock.json")
        let prose = root.appendingPathComponent("biology.md")
        let sourceText = (0..<2_000).map { index in
            index.isMultiple(of: 80)
                ? "func feature\(index)() { return \(index) }"
                : "let generatedValue\(index) = \(index)"
        }.joined(separator: "\n")
        let proseText = Array(repeating: "A useful paragraph about biology and lecture notes.", count: 500)
            .joined(separator: " ")
        try sourceText.write(to: source, atomically: true, encoding: .utf8)
        try "LOCK_SENTINEL generated dependency metadata".write(
            to: lockfile, atomically: true, encoding: .utf8)
        try proseText.write(to: prose, atomically: true, encoding: .utf8)

        let recorder = TextRecorder()
        var options = Indexer.Options()
        options.enableLocalEmbeddings = true
        options.enableOCR = false
        let provider = FixtureProvider(recorder: recorder)
        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(),
            options: options, embeddingProvider: provider)

        XCTAssertEqual(try indexer.indexRoot(root), 3)
        let inputs = recorder.snapshot
        XCTAssertEqual(inputs.filter { $0.contains("file: Engine.swift") }.count, 1,
                       "source code must have one compact primary embedding")
        XCTAssertLessThanOrEqual(inputs.count, 8,
                                 "one source capsule plus one prose primary and six chunks")
        XCTAssertTrue(inputs.allSatisfy { $0.count <= SemanticCompaction.maxPrimaryCharacters })

        let lockEmbeddingCount = try catalog.query(
            "SELECT count(*) FROM embeddings e JOIN files f ON f.id=e.file_id WHERE f.path=?",
            binds: [.text(lockfile.path)]) { $0.int(0) }.first ?? 0
        let lockChunkCount = try catalog.query(
            "SELECT count(*) FROM embedding_chunks c JOIN files f ON f.id=c.file_id WHERE f.path=?",
            binds: [.text(lockfile.path)]) { $0.int(0) }.first ?? 0
        XCTAssertEqual(lockEmbeddingCount, 0)
        XCTAssertEqual(lockChunkCount, 0)

        let summaries = try catalog.projectSemanticSummaries()
        XCTAssertEqual(summaries.count, 1)
        XCTAssertTrue(summaries[0].complete)
        XCTAssertEqual(summaries[0].fileCount, 3)
        XCTAssertEqual(summaries[0].embeddingFileCount, 2)
        XCTAssertLessThanOrEqual(summaries[0].chunkRowCount, 6)
        XCTAssertGreaterThan(summaries[0].vectorBytes, 0)

        let metrics = try catalog.semanticStorageMetrics()
        XCTAssertEqual(metrics.maxEmbeddingsPerFile, 1)
        XCTAssertLessThanOrEqual(metrics.maxChunksPerFile, 6)
        XCTAssertEqual(metrics.totalVectorBytes, summaries[0].vectorBytes)
    }
}
