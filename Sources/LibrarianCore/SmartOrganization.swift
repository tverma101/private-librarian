import Foundation

public enum SmartOrganizationGroupKind: String, Codable, Sendable {
    case category
    case nearDuplicate
    case semantic
}

/// A compact, human-facing virtual group. These are intentionally *not*
/// Finder folders: a file can appear in several groups while its source path
/// remains untouched.
public struct SmartOrganizationGroup: Identifiable, Sendable, Equatable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let kind: SmartOrganizationGroupKind
    public let fileIDs: [String]
    public let confidence: Double

    public init(id: String, title: String, subtitle: String,
                kind: SmartOrganizationGroupKind, fileIDs: [String],
                confidence: Double = 1) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
        self.fileIDs = fileIDs
        self.confidence = confidence
    }
}

/// Turns low-level catalog memberships and similarity components into a small
/// set of useful groups. The planner deliberately drops singleton taxonomy
/// leaves and caps the number of groups so a large library cannot become a
/// wall of thousands of AI-generated pseudo-folders.
public struct SmartOrganizationPlanner: Sendable {
    public let maxGroups: Int
    public let minimumGroupSize: Int
    public let minimumSemanticConfidence: Float

    private static let allowedCourseDepartments: Set<String> = [
        "ART", "BIO", "BUS", "CHM", "COM", "CSC", "ECO", "ENG",
        "FRE", "HIS", "MAT", "PHY", "PSY", "SOC", "SPA"
    ]

    private static let allowedScreenshotSubtypes: Set<String> = [
        "code", "school", "lms", "receipt", "error", "conversation",
        "social", "map", "meme", "reference"
    ]

    public init(maxGroups: Int = 18, minimumGroupSize: Int = 2,
                minimumSemanticConfidence: Float = 0.72) {
        self.maxGroups = max(1, maxGroups)
        self.minimumGroupSize = max(2, minimumGroupSize)
        self.minimumSemanticConfidence = minimumSemanticConfidence
    }

    public func build(
        memberships: [(categoryPath: String, fileID: String)],
        similarityClusters: [SimilarityCluster]
    ) -> [SmartOrganizationGroup] {
        var membersByCategory: [String: Set<String>] = [:]
        var categoriesByFile: [String: Set<String>] = [:]
        for membership in memberships {
            let path = Self.normalize(membership.categoryPath)
            guard !path.isEmpty, !membership.fileID.isEmpty else { continue }
            membersByCategory[path, default: []].insert(membership.fileID)
            categoriesByFile[membership.fileID, default: []].insert(path)
        }

        var candidates: [(priority: Int, group: SmartOrganizationGroup)] = []

        for (path, members) in membersByCategory {
            guard members.count >= minimumGroupSize,
                  let spec = Self.categorySpec(path) else { continue }
            candidates.append((
                spec.priority,
                SmartOrganizationGroup(
                    id: "category:\(path)",
                    title: spec.title,
                    subtitle: "\(members.count) items · \(spec.subtitle)",
                    kind: .category,
                    fileIDs: members.sorted()
                )
            ))
        }

        // Downloads/Desktop chaos is usually useful at a *concept* level, not
        // one pseudo-folder per extension. Merge installer-ish source kinds and
        // media kinds into two broad human buckets while keeping their lower-
        // level catalog evidence intact.
        let installerMembers = Self.unionMembers(
            ["Applications", "DiskImages", "Packages", "Archives"],
            from: membersByCategory
        )
        if installerMembers.count >= minimumGroupSize {
            candidates.append((
                96,
                SmartOrganizationGroup(
                    id: "composite:installers-archives",
                    title: "Installers & archives",
                    subtitle: "\(installerMembers.count) items · apps, disk images & archives",
                    kind: .category,
                    fileIDs: installerMembers.sorted()
                )
            ))
        }

        let mediaMembers = Self.unionMembers(["Audio", "Video"], from: membersByCategory)
        if mediaMembers.count >= minimumGroupSize {
            candidates.append((
                92,
                SmartOrganizationGroup(
                    id: "composite:media",
                    title: "Recordings & media",
                    subtitle: "\(mediaMembers.count) items · audio & video",
                    kind: .category,
                    fileIDs: mediaMembers.sorted()
                )
            ))
        }

        for cluster in similarityClusters {
            let members = Array(Set(cluster.members)).sorted()
            guard members.count >= 2 else { continue }
            switch cluster.relation {
            case .nearDuplicate:
                candidates.append((
                    120,
                    SmartOrganizationGroup(
                        id: "duplicate:\(cluster.familyID)",
                        title: "Near-duplicate family",
                        subtitle: "\(members.count) almost-identical files",
                        kind: .nearDuplicate,
                        fileIDs: members,
                        confidence: Double(cluster.confidence)
                    )
                ))
            case .semantic:
                guard members.count >= max(3, minimumGroupSize),
                      cluster.confidence >= minimumSemanticConfidence else { continue }
                let title = Self.semanticTitle(members: members, categoriesByFile: categoriesByFile)
                candidates.append((
                    85,
                    SmartOrganizationGroup(
                        id: "semantic:\(cluster.familyID)",
                        title: title,
                        subtitle: "\(members.count) related items",
                        kind: .semantic,
                        fileIDs: members,
                        confidence: Double(cluster.confidence)
                    )
                ))
            }
        }

        // A stable sort makes the home screen predictable. Per-lane limits then
        // prevent a noisy signal (for example dozens of duplicate families) from
        // consuming every visible smart group.
        let sorted = candidates.sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.group.fileIDs.count != $1.group.fileIDs.count {
                return $0.group.fileIDs.count > $1.group.fileIDs.count
            }
            if $0.group.title != $1.group.title { return $0.group.title < $1.group.title }
            return $0.group.id < $1.group.id
        }
        var selected: [SmartOrganizationGroup] = []
        var laneCounts: [String: Int] = [:]
        for candidate in sorted {
            let lane = Self.lane(for: candidate.group)
            guard laneCounts[lane, default: 0] < Self.laneLimit(lane, maxGroups: maxGroups) else {
                continue
            }
            selected.append(candidate.group)
            laneCounts[lane, default: 0] += 1
            if selected.count == maxGroups { break }
        }
        return selected
    }

    private static func unionMembers(
        _ paths: [String],
        from membersByCategory: [String: Set<String>]
    ) -> Set<String> {
        paths.reduce(into: Set<String>()) { result, path in
            result.formUnion(membersByCategory[path] ?? [])
        }
    }

    private static func lane(for group: SmartOrganizationGroup) -> String {
        switch group.kind {
        case .nearDuplicate:
            return "duplicates"
        case .semantic:
            return "semantic"
        case .category:
            if group.id == "composite:installers-archives" { return "downloads" }
            if group.id == "composite:media" { return "media" }
            if group.id == "category:Image/Junk" { return "junk" }
            if group.id.hasPrefix("category:Screenshots/") { return "screenshots" }
            if group.id.hasPrefix("category:School/") { return "school" }
            if group.id.hasPrefix("category:Projects/") { return "projects" }
            return "general"
        }
    }

    private static func laneLimit(_ lane: String, maxGroups: Int) -> Int {
        let preferred: Int
        switch lane {
        case "duplicates": preferred = 3
        case "screenshots": preferred = 4
        case "school": preferred = 4
        case "projects": preferred = 2
        case "semantic": preferred = 5
        case "downloads", "media", "junk": preferred = 1
        default: preferred = 4
        }
        return min(maxGroups, preferred)
    }

    private static func semanticTitle(
        members: [String],
        categoriesByFile: [String: Set<String>]
    ) -> String {
        var support: [String: Int] = [:]
        for member in members {
            for category in categoriesByFile[member] ?? [] where categorySpec(category) != nil {
                support[category, default: 0] += 1
            }
        }
        if let best = support
            .filter({ $0.value >= 2 })
            .sorted(by: {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }).first,
           let spec = categorySpec(best.key) {
            return "Related \(spec.title)"
        }
        return "Related items"
    }

    private static func normalize(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "/")
    }

    /// Presentation-layer taxonomy firewall. Catalog rows can come from old
    /// classifiers, imports, learned rules, or future model providers, so the
    /// dashboard must never assume that a repeated category string is safe or
    /// useful merely because more than one file has it.
    private static func categorySpec(_ path: String) ->
        (title: String, subtitle: String, priority: Int)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard let root = parts.first else { return nil }

        if root == "Screenshots", parts.count == 2,
           let subtype = canonicalScreenshotSubtype(parts[1]) {
            return ("\(humanize(subtype)) screenshots", "Screenshots", 112)
        }
        if root == "School", parts.count == 2,
           let course = canonicalCourse(parts[1]) {
            return (course, "School", 110)
        }
        if path == "Projects/Code" {
            return ("Code projects", "Projects", 106)
        }
        if path == "Assignment" {
            return ("Assignments", "School & work", 100)
        }
        if path == "Image/Junk" { return ("Likely image junk", "Review before deleting", 108) }
        if path == "Documents/PDF" { return ("PDFs", "Documents", 90) }
        if path == "Documents/Office" { return ("Office documents", "Documents", 90) }
        if path == "Image/Animals" { return ("Animals", "Images", 82) }
        if path == "Image/Vehicles" { return ("Vehicles", "Images", 82) }
        if path == "Image/Scenery" { return ("Scenery", "Images", 82) }
        if path == "Image/Food" { return ("Food", "Images", 82) }
        if path == "Image/Documents" { return ("Document photos", "Images", 82) }
        return nil
    }

    private static func canonicalScreenshotSubtype(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let canonical = value.lowercased()
        guard value == canonical, allowedScreenshotSubtypes.contains(canonical) else { return nil }
        return canonical
    }

    private static func canonicalCourse(_ value: String) -> String? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value == value.uppercased() else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let department = String(pieces[0])
        let number = String(pieces[1])
        guard allowedCourseDepartments.contains(department),
              (3...4).contains(number.count),
              number.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            return nil
        }
        return "\(department)-\(number)"
    }

    private static func humanize(_ value: String) -> String {
        value.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                let lower = word.lowercased()
                if ["lms", "pdf", "ui"].contains(lower) { return lower.uppercased() }
                return lower.prefix(1).uppercased() + String(lower.dropFirst())
            }
            .joined(separator: " ")
    }
}

public extension Catalog {
    func smartOrganizationGroups(limit: Int = 18) throws -> [SmartOrganizationGroup] {
        SmartOrganizationPlanner(maxGroups: limit).build(
            memberships: try categoryMemberships(),
            similarityClusters: try similarityClusters()
        )
    }

    /// Remove category rows that no longer lead to any membership. This is
    /// catalog-only cleanup: source files are never touched. Ancestors of an
    /// active category are retained so hierarchical paths remain intact.
    func pruneUnusedVirtualCategories() throws {
        try run("""
            WITH RECURSIVE used(id) AS (
                SELECT DISTINCT category_id FROM category_membership
                UNION
                SELECT c.parent_id
                FROM virtual_categories c
                JOIN used u ON c.id = u.id
                WHERE c.parent_id IS NOT NULL
            )
            DELETE FROM virtual_categories
            WHERE id NOT IN (SELECT id FROM used)
            """)
    }
}
