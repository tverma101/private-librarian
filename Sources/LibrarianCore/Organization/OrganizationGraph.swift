import Foundation

/// Relationships used by the virtual organization graph. These are catalog
/// facts only; none of them authorizes a source-file move, rename, or delete.
public enum OrganizationRelation: String, Codable, Sendable, CaseIterable {
    case category
    case review
    case missing
    case duplicate
    case semantic
}

public struct OrganizationGraphNode: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let label: String
    public let kind: String

    public init(id: String, label: String, kind: String) {
        self.id = id
        self.label = label
        self.kind = kind
    }
}

public struct OrganizationGraphEdge: Codable, Sendable, Equatable, Hashable {
    public let sourceID: String
    public let targetID: String
    public let relation: OrganizationRelation
    public let weight: Double

    public init(sourceID: String, targetID: String,
                relation: OrganizationRelation, weight: Double = 1) {
        self.sourceID = sourceID
        self.targetID = targetID
        self.relation = relation
        self.weight = weight
    }
}

public struct OrganizationGraphSnapshot: Codable, Sendable, Equatable {
    public let nodes: [OrganizationGraphNode]
    public let edges: [OrganizationGraphEdge]

    public init(nodes: [OrganizationGraphNode], edges: [OrganizationGraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static let empty = OrganizationGraphSnapshot(nodes: [], edges: [])
}

/// Deterministic graph construction from catalog facts. Category memberships
/// are intentionally many-to-many: a file may belong to School and
/// Screenshot, for example, without being copied or moved anywhere.
public struct OrganizationGraphBuilder: Sendable {
    public init() {}

    public func build(
        files: [(id: String, path: String, status: String, kind: String)],
        memberships: [(categoryPath: String, fileID: String)],
        reviewFileIDs: Set<String> = [],
        similarityClusters: [SimilarityCluster] = [],
        extraEdges: [OrganizationGraphEdge] = []
    ) -> OrganizationGraphSnapshot {
        var nodes: [String: OrganizationGraphNode] = [:]
        var edges: [String: OrganizationGraphEdge] = [:]

        for file in files {
            let fileNodeID = Self.fileNodeID(file.id)
            nodes[fileNodeID] = OrganizationGraphNode(
                id: fileNodeID,
                label: (file.path as NSString).lastPathComponent,
                kind: file.kind.isEmpty ? "file" : file.kind
            )
            if file.status == "missing" {
                let missingID = Self.categoryNodeID("Missing")
                nodes[missingID] = OrganizationGraphNode(id: missingID, label: "Missing", kind: "status")
                Self.insert(OrganizationGraphEdge(sourceID: fileNodeID, targetID: missingID,
                                                   relation: .missing), into: &edges)
            }
            if reviewFileIDs.contains(file.id) {
                let reviewID = Self.categoryNodeID("Review")
                nodes[reviewID] = OrganizationGraphNode(id: reviewID, label: "Review", kind: "status")
                Self.insert(OrganizationGraphEdge(sourceID: fileNodeID, targetID: reviewID,
                                                   relation: .review), into: &edges)
            }
        }

        for membership in memberships {
            let categoryPath = Self.normalizedCategoryPath(membership.categoryPath)
            guard nodes[Self.fileNodeID(membership.fileID)] != nil,
                  !categoryPath.isEmpty else { continue }
            let categoryID = Self.categoryNodeID(categoryPath)
            nodes[categoryID] = OrganizationGraphNode(id: categoryID,
                                                       label: categoryPath,
                                                       kind: "category")
            Self.insert(OrganizationGraphEdge(
                sourceID: Self.fileNodeID(membership.fileID),
                targetID: categoryID,
                relation: .category
            ), into: &edges)
        }

        for cluster in similarityClusters {
            let members = Array(Set(cluster.members)).filter {
                nodes[Self.fileNodeID($0)] != nil
            }.sorted()
            guard !cluster.id.isEmpty, !members.isEmpty,
                  cluster.confidence.isFinite else { continue }
            let clusterNodeID = Self.clusterNodeID(cluster.id)
            let label = cluster.relation == .nearDuplicate
                ? "Near-duplicate family"
                : "Semantic cluster"
            nodes[clusterNodeID] = OrganizationGraphNode(
                id: clusterNodeID, label: label, kind: "similarity")
            let relation: OrganizationRelation = cluster.relation == .nearDuplicate
                ? .duplicate : .semantic
            let weight = min(1, max(0, Double(cluster.confidence)))
            for member in members {
                Self.insert(OrganizationGraphEdge(
                    sourceID: Self.fileNodeID(member),
                    targetID: clusterNodeID,
                    relation: relation,
                    weight: weight
                ), into: &edges)
            }
        }

        for edge in extraEdges {
            guard nodes[edge.sourceID] != nil, nodes[edge.targetID] != nil,
                  edge.weight.isFinite, edge.weight >= 0 else { continue }
            Self.insert(edge, into: &edges)
        }

        return OrganizationGraphSnapshot(
            nodes: nodes.values.sorted { $0.id < $1.id },
            edges: edges.values.sorted {
                ($0.sourceID, $0.targetID, $0.relation.rawValue) <
                    ($1.sourceID, $1.targetID, $1.relation.rawValue)
            }
        )
    }

    public static func fileNodeID(_ fileID: String) -> String { "file:\(fileID)" }
    public static func categoryNodeID(_ categoryPath: String) -> String { "category:\(categoryPath)" }
    public static func clusterNodeID(_ clusterID: String) -> String { "cluster:\(clusterID)" }

    private static func normalizedCategoryPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    private static func insert(_ edge: OrganizationGraphEdge,
                               into edges: inout [String: OrganizationGraphEdge]) {
        let key = "\(edge.sourceID)\u{1f}\(edge.targetID)\u{1f}\(edge.relation.rawValue)"
        if let old = edges[key], old.weight >= edge.weight { return }
        edges[key] = edge
    }
}
