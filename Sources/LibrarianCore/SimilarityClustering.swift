import Foundation

public struct SimilarityEdge: Sendable, Equatable {
    public let a: String
    public let b: String
    public let score: Float

    public init(a: String, b: String, score: Float) {
        self.a = a
        self.b = b
        self.score = score
    }
}

public struct SimilarityCluster: Sendable, Equatable {
    public let id: String
    public let members: [String]
    public let representative: String

    public init(id: String, members: [String], representative: String) {
        self.id = id
        self.members = members
        self.representative = representative
    }
}

/// Small, deterministic connected-components engine for thresholded similarity graphs.
/// This intentionally keeps ANN/model concerns outside the clustering layer.
public struct SimilarityClustering: Sendable {
    public init() {}

    public func clusters(nodes: [String], edges: [SimilarityEdge], minimumScore: Float) -> [SimilarityCluster] {
        let uniqueNodes = Array(Set(nodes)).sorted()
        guard !uniqueNodes.isEmpty else { return [] }

        var parent: [String: String] = Dictionary(uniqueKeysWithValues: uniqueNodes.map { ($0, $0) })

        func root(_ node: String, _ parent: inout [String: String]) -> String {
            var cursor = node
            while let next = parent[cursor], next != cursor {
                cursor = next
            }
            let r = cursor
            cursor = node
            while let next = parent[cursor], next != cursor {
                let old = cursor
                cursor = next
                parent[old] = r
            }
            return r
        }

        func union(_ a: String, _ b: String, _ parent: inout [String: String]) {
            guard parent[a] != nil, parent[b] != nil else { return }
            let ra = root(a, &parent)
            let rb = root(b, &parent)
            guard ra != rb else { return }
            if ra < rb { parent[rb] = ra } else { parent[ra] = rb }
        }

        for edge in edges where edge.score >= minimumScore {
            union(edge.a, edge.b, &parent)
        }

        var groups: [String: [String]] = [:]
        for node in uniqueNodes {
            let r = root(node, &parent)
            groups[r, default: []].append(node)
        }

        return groups.values
            .filter { $0.count >= 2 }
            .map { members in
                let sorted = members.sorted()
                let representative = representativeFor(members: sorted, edges: edges, minimumScore: minimumScore)
                return SimilarityCluster(
                    id: stableClusterID(sorted),
                    members: sorted,
                    representative: representative
                )
            }
            .sorted { $0.id < $1.id }
    }

    private func representativeFor(members: [String], edges: [SimilarityEdge], minimumScore: Float) -> String {
        var weightedDegree: [String: Float] = Dictionary(uniqueKeysWithValues: members.map { ($0, 0) })
        let memberSet = Set(members)
        for edge in edges where edge.score >= minimumScore && memberSet.contains(edge.a) && memberSet.contains(edge.b) {
            weightedDegree[edge.a, default: 0] += edge.score
            weightedDegree[edge.b, default: 0] += edge.score
        }
        return members.max { lhs, rhs in
            let l = weightedDegree[lhs, default: 0]
            let r = weightedDegree[rhs, default: 0]
            if l == r { return lhs > rhs }
            return l < r
        } ?? members[0]
    }

    private func stableClusterID(_ members: [String]) -> String {
        var hash: UInt64 = 1469598103934665603
        for byte in members.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "cluster-%016llx", hash)
    }
}
