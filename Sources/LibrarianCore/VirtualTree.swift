import Foundation

/// Virtual organization (plan §25-§28): the app never creates real
/// directories. Trees are built from category membership in the catalog.
public struct VirtualTree: Sendable {

    public struct Node: Sendable {
        public let name: String
        public var children: [Node]
        public var fileIDs: [String]
    }

    /// Build the tree from flat "A/B/C" category paths + memberships.
    public static func build(memberships: [(categoryPath: String, fileID: String)]) -> Node {
        let root = Node(name: "", children: [], fileIDs: [])
        var nodes: [String: Node] = [:]

        func ensure(_ path: String) -> String {
            guard nodes[path] == nil else { return path }
            let comps = path.split(separator: "/").map(String.init)
            let name = comps.last ?? path
            nodes[path] = Node(name: name, children: [], fileIDs: [])
            if comps.count > 1 {
                let parentPath = comps.dropLast().joined(separator: "/")
                _ = ensure(parentPath)
            }
            return path
        }

        for m in memberships {
            let p = ensure(m.categoryPath)
            nodes[p]?.fileIDs.append(m.fileID)
        }

        // Assemble hierarchy.
        var result = root
        for path in nodes.keys.sorted() {
            let comps = path.split(separator: "/").map(String.init)
            guard var node = nodes[path] else { continue }
            node.children.sort { $0.name < $1.name }
            if comps.count == 1 {
                result.children.append(node)
            } else {
                let parentPath = comps.dropLast().joined(separator: "/")
                nodes[parentPath]?.children.append(node)
            }
        }
        result.children.sort { $0.name < $1.name }
        return result
    }
}

/// Confidence handling (plan §27): three visible states, never hidden.
public enum ReviewState: String, Sendable {
    case confident, ambiguous, needsReview

    public static func from(confidence: Double) -> ReviewState {
        switch ConfidenceBand.band(forConfidence: confidence) {
        case .confident: return .confident
        case .ambiguous: return .ambiguous
        case .unknown: return .needsReview
        }
    }
}
