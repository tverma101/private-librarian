import Foundation

public enum SimilarityRelation: String, Codable, Sendable, CaseIterable { case nearDuplicate, semantic }
public enum SimilaritySignal: String, Codable, Sendable, CaseIterable { case exactHash, featurePrint, embedding }

public struct SimilarityNode: Sendable, Equatable {
    public let id: String
    public let exactHash: Data?
    public let featurePrint: Data?
    public let embeddings: [String: Data]
    /// Optional upstream confidence; only used as a deterministic tie-breaker.
    public let confidence: Float
    public init(id: String, exactHash: Data? = nil, featurePrint: Data? = nil,
                embeddings: [String: Data] = [:], confidence: Float = 0) {
        self.id = id; self.exactHash = exactHash; self.featurePrint = featurePrint
        self.embeddings = embeddings; self.confidence = confidence
    }
}

public struct SimilarityEdge: Sendable, Equatable {
    public let a: String; public let b: String; public let score: Float
    public let relation: SimilarityRelation; public let signal: SimilaritySignal
    public init(a: String, b: String, score: Float,
                relation: SimilarityRelation = .nearDuplicate,
                signal: SimilaritySignal = .featurePrint) {
        if a <= b { self.a = a; self.b = b } else { self.a = b; self.b = a }
        self.score = score; self.relation = relation; self.signal = signal
    }
}

public struct SimilarityCluster: Sendable, Equatable {
    public let id: String; public let familyID: String
    public let relation: SimilarityRelation; public let members: [String]; public let representative: String
    public init(id: String, members: [String], representative: String,
                relation: SimilarityRelation = .nearDuplicate, familyID: String? = nil) {
        self.id = id; self.familyID = familyID ?? id.replacingOccurrences(of: "cluster-", with: "family-", options: [.anchored])
        self.relation = relation; self.members = members; self.representative = representative
    }
}

public protocol SimilarityEdgeAdapter: Sendable {
    var signal: SimilaritySignal { get }; var relation: SimilarityRelation { get }
    func edges(from node: SimilarityNode, candidates: [SimilarityNode]) -> [SimilarityEdge]
}

/// The producer may use any exact digest; the graph engine does not select a hash provider.
public struct ExactHashEdgeAdapter: SimilarityEdgeAdapter {
    public let signal = SimilaritySignal.exactHash; public let relation = SimilarityRelation.nearDuplicate
    public init() {}
    public func edges(from node: SimilarityNode, candidates: [SimilarityNode]) -> [SimilarityEdge] {
        guard let hash = node.exactHash else { return [] }
        return candidates.compactMap { other in
            guard other.id != node.id, let otherHash = other.exactHash, hash == otherHash else { return nil }
            return SimilarityEdge(a: node.id, b: other.id, score: 1, relation: relation, signal: signal)
        }
    }
}

public protocol FeaturePrintScorer: Sendable { func score(_ lhs: Data, _ rhs: Data) -> Float? }
public struct FeaturePrintEdgeAdapter: SimilarityEdgeAdapter {
    public let signal = SimilaritySignal.featurePrint; public let relation = SimilarityRelation.nearDuplicate
    private let scorer: any FeaturePrintScorer; public let minimumScore: Float
    public init(scorer: any FeaturePrintScorer, minimumScore: Float) { self.scorer = scorer; self.minimumScore = minimumScore }
    public func edges(from node: SimilarityNode, candidates: [SimilarityNode]) -> [SimilarityEdge] {
        guard let value = node.featurePrint else { return [] }
        return candidates.compactMap { other in
            guard other.id != node.id, let otherValue = other.featurePrint,
                  let score = scorer.score(value, otherValue), score >= minimumScore else { return nil }
            return SimilarityEdge(a: node.id, b: other.id, score: score, relation: relation, signal: signal)
        }
    }
}

public protocol EmbeddingScorer: Sendable { func score(_ lhs: Data, _ rhs: Data, model: String) -> Float? }
public struct EmbeddingEdgeAdapter: SimilarityEdgeAdapter {
    public let signal = SimilaritySignal.embedding; public let relation = SimilarityRelation.semantic
    private let scorer: any EmbeddingScorer; public let model: String; public let minimumScore: Float
    public init(model: String, scorer: any EmbeddingScorer, minimumScore: Float) {
        self.model = model; self.scorer = scorer; self.minimumScore = minimumScore
    }
    public func edges(from node: SimilarityNode, candidates: [SimilarityNode]) -> [SimilarityEdge] {
        guard let value = node.embeddings[model] else { return [] }
        return candidates.compactMap { other in
            guard other.id != node.id, let otherValue = other.embeddings[model],
                  let score = scorer.score(value, otherValue, model: model), score >= minimumScore else { return nil }
            return SimilarityEdge(a: node.id, b: other.id, score: score, relation: relation, signal: signal)
        }
    }
}

public enum SimilarityChange: Sendable { case add, change, missing }
public struct SimilarityGraphUpdate: Sendable, Equatable {
    public let edges: [SimilarityEdge]; public let clusters: [SimilarityCluster]
    public init(edges: [SimilarityEdge], clusters: [SimilarityCluster]) { self.edges = edges; self.clusters = clusters }
}

/// Provider-neutral deterministic threshold graph and connected-components engine.
public struct SimilarityClustering: Sendable {
    public init() {}
    public func edges(nodes: [SimilarityNode], adapters: [any SimilarityEdgeAdapter]) -> [SimilarityEdge] {
        let sorted = dedupeNodes(nodes); var result: [SimilarityEdge] = []
        for node in sorted { for adapter in adapters { result += adapter.edges(from: node, candidates: sorted) } }
        return canonicalEdges(result)
    }

    public func clusters(nodes: [String], edges: [SimilarityEdge], minimumScore: Float,
                         relation: SimilarityRelation? = nil, confidence: [String: Float] = [:]) -> [SimilarityCluster] {
        let uniqueNodes = Array(Set(nodes)).sorted(); guard !uniqueNodes.isEmpty else { return [] }
        var parent = Dictionary(uniqueKeysWithValues: uniqueNodes.map { ($0, $0) })
        func root(_ node: String, _ p: inout [String: String]) -> String {
            var cursor = node; while let next = p[cursor], next != cursor { cursor = next }
            let r = cursor; cursor = node
            while let next = p[cursor], next != cursor { p[cursor] = r; cursor = next }
            return r
        }
        func union(_ a: String, _ b: String, _ p: inout [String: String]) {
            guard p[a] != nil, p[b] != nil else { return }; let ra = root(a, &p), rb = root(b, &p); guard ra != rb else { return }
            if ra < rb { p[rb] = ra } else { p[ra] = rb }
        }
        let usable = canonicalEdges(edges).filter { $0.score >= minimumScore && (relation == nil || $0.relation == relation) }
        for edge in usable { union(edge.a, edge.b, &parent) }
        var groups: [String: [String]] = [:]; for node in uniqueNodes { groups[root(node, &parent), default: []].append(node) }
        return groups.values.filter { $0.count >= 2 }.map { members in
            let sorted = members.sorted(); let rel = relation ?? dominantRelation(sorted, edges: usable)
            let id = stableID(prefix: "cluster", relation: rel, members: sorted)
            return SimilarityCluster(id: id, members: sorted,
                                     representative: representativeFor(members: sorted, edges: usable, confidence: confidence),
                                     relation: rel, familyID: stableID(prefix: "family", relation: rel, members: sorted))
        }.sorted { $0.id < $1.id }
    }

    /// Retain unaffected edges and rescore only changed nodes' neighborhoods.
    /// `missing` is represented by `removedNodeIDs` and never deletes source files.
    public func incrementalUpdate(nodes: [SimilarityNode], existingEdges: [SimilarityEdge],
                                  changedNodeIDs: Set<String>, removedNodeIDs: Set<String> = [],
                                  adapters: [any SimilarityEdgeAdapter], minimumScore: Float,
                                  relation: SimilarityRelation? = nil) -> SimilarityGraphUpdate {
        let live = dedupeNodes(nodes).filter { !removedNodeIDs.contains($0.id) }; let ids = Set(live.map(\.id))
        let affected = changedNodeIDs.union(removedNodeIDs)
        var retained = existingEdges.filter { ids.contains($0.a) && ids.contains($0.b) && !affected.contains($0.a) && !affected.contains($0.b) }
        retained += edges(nodes: live.filter { affected.contains($0.id) }, adapters: adapters).filter { ids.contains($0.a) && ids.contains($0.b) }
        let finalEdges = canonicalEdges(retained)
        let confidence = Dictionary(uniqueKeysWithValues: live.map { ($0.id, $0.confidence) })
        return SimilarityGraphUpdate(edges: finalEdges,
            clusters: clusters(nodes: live.map(\.id), edges: finalEdges, minimumScore: minimumScore, relation: relation, confidence: confidence))
    }

    public func incrementalUpdate(nodes: [SimilarityNode], existingEdges: [SimilarityEdge],
                                  changes: [String: SimilarityChange], adapters: [any SimilarityEdgeAdapter],
                                  minimumScore: Float, relation: SimilarityRelation? = nil) -> SimilarityGraphUpdate {
        let removed = Set(changes.compactMap { $0.value == .missing ? $0.key : nil })
        return incrementalUpdate(nodes: nodes, existingEdges: existingEdges,
                                 changedNodeIDs: Set(changes.keys), removedNodeIDs: removed,
                                 adapters: adapters, minimumScore: minimumScore, relation: relation)
    }

    private func dedupeNodes(_ nodes: [SimilarityNode]) -> [SimilarityNode] {
        Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { lhs, _ in lhs }).values.sorted { $0.id < $1.id }
    }
    private func canonicalEdges(_ edges: [SimilarityEdge]) -> [SimilarityEdge] {
        Dictionary(edges.map { ("\($0.a)\u{1f}\($0.b)\u{1f}\($0.relation.rawValue)\u{1f}\($0.signal.rawValue)", $0) }, uniquingKeysWith: { lhs, rhs in lhs.score >= rhs.score ? lhs : rhs }).values.sorted {
            ($0.a, $0.b, $0.relation.rawValue, $0.signal.rawValue) < ($1.a, $1.b, $1.relation.rawValue, $1.signal.rawValue)
        }
    }
    private func dominantRelation(_ members: [String], edges: [SimilarityEdge]) -> SimilarityRelation {
        let counts = edges.filter { members.contains($0.a) && members.contains($0.b) }.reduce(into: [SimilarityRelation: Int]()) { $0[$1.relation, default: 0] += 1 }
        return counts[.nearDuplicate, default: 0] >= counts[.semantic, default: 0] ? .nearDuplicate : .semantic
    }
    private func representativeFor(members: [String], edges: [SimilarityEdge], confidence: [String: Float]) -> String {
        var degree = Dictionary(uniqueKeysWithValues: members.map { ($0, Float(0)) }); let set = Set(members)
        for edge in edges where set.contains(edge.a) && set.contains(edge.b) { degree[edge.a, default: 0] += edge.score; degree[edge.b, default: 0] += edge.score }
        return members.max { lhs, rhs in
            let l = (degree[lhs, default: 0], confidence[lhs, default: 0]), r = (degree[rhs, default: 0], confidence[rhs, default: 0])
            return l == r ? lhs > rhs : l < r
        } ?? members[0]
    }
    private func stableID(prefix: String, relation: SimilarityRelation, members: [String]) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in (relation.rawValue + "\u{1e}" + members.joined(separator: "\u{1f}")).utf8 { hash ^= UInt64(byte); hash = hash &* 1099511628211 }
        return String(format: "%@-%016llx", prefix, hash)
    }
}
