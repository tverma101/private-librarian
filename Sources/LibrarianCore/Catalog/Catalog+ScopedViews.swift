import Foundation

extension Catalog {
    /// Build a path-boundary predicate for an optional set of authorized roots.
    /// An omitted scope preserves the historical aggregate query; an explicit
    /// empty scope matches no roots. Paths are compared by component boundary, never by an unsafe raw
    /// prefix (`/Users/me/Down` must not match `/Users/me/Downloads`).
    func scopedRootPredicate(column: String, roots: [String]?) -> (sql: String, binds: [SQLValue]) {
        guard let roots else { return ("", []) }
        let normalizedRoots = roots.map { root in
            guard root.count > 1, root.hasSuffix("/") else { return root }
            return String(root.dropLast())
        }
        .filter { !$0.isEmpty }
        .sorted()

        guard !normalizedRoots.isEmpty else { return ("0", []) }

        var clauses: [String] = []
        var binds: [SQLValue] = []
        for root in normalizedRoots {
            if root == "/" {
                clauses.append("\(column) LIKE ?")
                binds.append(.text("/%"))
            } else {
                clauses.append("(\(column)=? OR substr(\(column),1,length(?) + 1)=? || '/')")
                binds.append(contentsOf: [.text(root), .text(root), .text(root)])
            }
        }
        return ("(" + clauses.joined(separator: " OR ") + ")", binds)
    }
}
