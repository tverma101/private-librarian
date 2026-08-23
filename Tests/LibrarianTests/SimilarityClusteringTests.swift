import XCTest
@testable import LibrarianCore

private struct SyntheticFeatureScorer: FeaturePrintScorer {
    func score(_ lhs: Data, _ rhs: Data) -> Float? {
        guard lhs.count == rhs.count else { return nil }
        let distance = zip(lhs, rhs).reduce(0) { $0 + ($1.0 == $1.1 ? 0 : 1) }
        return 1 - Float(distance) / Float(max(lhs.count, 1))
    }
}

private struct SyntheticEmbeddingScorer: EmbeddingScorer {
    func score(_ lhs: Data, _ rhs: Data, model: String) -> Float? {
        guard lhs.count == rhs.count else { return nil }
        return lhs == rhs ? 1 : 0.8
    }
}

final class SimilarityClusteringTests: XCTestCase {
    private func node(_ id: String, _ feature: [UInt8], hash: String? = nil, confidence: Float = 0.5) -> SimilarityNode {
        SimilarityNode(id: id, exactHash: hash.map { Data($0.utf8) }, featurePrint: Data(feature), confidence: confidence)
    }

    func testSyntheticCropsResizesAndScreenshotsClusterAsNearDuplicates() {
        let engine = SimilarityClustering()
        // crop, resize, and screenshot-of-screenshot are intentionally close;
        // the unrelated lookalike has a different feature signature.
        let nodes = [node("crop", [10, 10, 10, 11]), node("resize", [10, 10, 11, 11]),
                     node("screenshot", [10, 11, 11, 11]), node("lookalike", [10, 30, 10, 30])]
        let adapter = FeaturePrintEdgeAdapter(scorer: SyntheticFeatureScorer(), minimumScore: 0.70)
        let edges = engine.edges(nodes: nodes, adapters: [adapter])
        let clusters = engine.clusters(nodes: nodes.map(\.id), edges: edges, minimumScore: 0.70)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].members, ["crop", "resize", "screenshot"])
        XCTAssertEqual(clusters[0].relation, .nearDuplicate)
        XCTAssertEqual(clusters[0].representative, "resize") // highest weighted degree; ties are lexical
        XCTAssertTrue(edges.allSatisfy { $0.relation == .nearDuplicate })
    }

    func testExactAndSemanticRelationsRemainExplicitAndProviderNeutral() {
        let engine = SimilarityClustering()
        let a = SimilarityNode(id: "a", exactHash: Data("same".utf8), embeddings: ["test-model": Data([1])])
        let b = SimilarityNode(id: "b", exactHash: Data("same".utf8), embeddings: ["test-model": Data([2])])
        let exact = ExactHashEdgeAdapter()
        let semantic = EmbeddingEdgeAdapter(model: "test-model", scorer: SyntheticEmbeddingScorer(), minimumScore: 0.7)
        let edges = engine.edges(nodes: [a, b], adapters: [exact, semantic])
        XCTAssertEqual(edges.map(\.relation), [.nearDuplicate, .semantic])
        XCTAssertEqual(engine.clusters(nodes: ["a", "b"], edges: edges, minimumScore: 0.9, relation: .nearDuplicate).count, 1)
        XCTAssertEqual(engine.clusters(nodes: ["a", "b"], edges: edges, minimumScore: 0.9, relation: .semantic).count, 0)
    }

    func testStableClusterAndRepresentativeIDsAreOrderIndependent() {
        let engine = SimilarityClustering()
        let forward = [SimilarityEdge(a: "b", b: "a", score: 0.9), SimilarityEdge(a: "b", b: "c", score: 0.9)]
        let reverse = Array(forward.reversed())
        let left = engine.clusters(nodes: ["c", "a", "b"], edges: forward, minimumScore: 0.8)
        let right = engine.clusters(nodes: ["b", "a", "c"], edges: reverse, minimumScore: 0.8)
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.first?.familyID, left.first?.familyID)
        XCTAssertEqual(left.first?.representative, "b")
    }

    func testIncrementalAddChangeAndMissingOnlyTouchNeighborhood() {
        let engine = SimilarityClustering()
        let adapter = FeaturePrintEdgeAdapter(scorer: SyntheticFeatureScorer(), minimumScore: 0.75)
        let a = node("a", [1, 1, 1, 1]); let b = node("b", [1, 1, 1, 2]); let c = node("c", [9, 9, 9, 9])
        let initial = engine.incrementalUpdate(nodes: [a, b], existingEdges: [], changedNodeIDs: ["a", "b"], adapters: [adapter], minimumScore: 0.75)
        XCTAssertEqual(initial.edges.count, 1)
        let added = engine.incrementalUpdate(nodes: [a, b, c], existingEdges: initial.edges, changedNodeIDs: ["c"], adapters: [adapter], minimumScore: 0.75)
        XCTAssertEqual(added.edges, initial.edges)
        let missing = engine.incrementalUpdate(nodes: [a, c], existingEdges: added.edges, changedNodeIDs: [], removedNodeIDs: ["b"], adapters: [adapter], minimumScore: 0.75)
        XCTAssertTrue(missing.edges.isEmpty); XCTAssertTrue(missing.clusters.isEmpty)
    }

    func testSimilarityGraphPersistsInsideEncryptedCatalog() throws {
        let catalog = try TestSupport.makeCatalog(tag: "similarity-persistence")
        for (index, id) in ["a", "b"].enumerated() {
            try catalog.upsertFile(identity: FileIdentity(path: "/tmp/\(id)", volumeUUID: nil, fileID: UInt64(index + 1), size: 1, mtime: Date(), ctime: Date(), kind: .image, isSymlink: false), id: id)
        }
        let edge = SimilarityEdge(a: "a", b: "b", score: 1, relation: .nearDuplicate, signal: .exactHash)
        let cluster = SimilarityCluster(id: "cluster-test", members: ["a", "b"], representative: "a", familyID: "family-test")
        try catalog.replaceSimilarityGraph(SimilarityGraphUpdate(edges: [edge], clusters: [cluster]))
        XCTAssertEqual(try catalog.similarityEdges(), [edge])
        XCTAssertEqual(try catalog.similarityClusters().first, cluster)
    }
}
