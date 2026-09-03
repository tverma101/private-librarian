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

        // Assemble hierarchy. Recursive assembly guarantees each child
        // subtree is complete before it is attached to its parent. The
        // previous iterative loop appended struct copies whose `children`
        // arrays were still empty (value semantics), so every nested
        // category was silently dropped from the result.
        var result = root
        var childrenByParent: [String: [String]] = [:]
        for path in nodes.keys {
            let comps = path.split(separator: "/").map(String.init)
            guard comps.count > 1 else { continue }
            childrenByParent[comps.dropLast().joined(separator: "/"), default: []].append(path)
        }
        func assemble(_ path: String) -> Node {
            guard var node = nodes[path] else {
                let comps = path.split(separator: "/").map(String.init)
                return Node(name: comps.last ?? path, children: [], fileIDs: [])
            }
            node.children = (childrenByParent[path] ?? []).sorted().map(assemble)
            return node
        }
        result.children = nodes.keys
            .filter { !$0.isEmpty && !$0.contains("/") }
            .sorted()
            .map(assemble)
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
