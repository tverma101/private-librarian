import Foundation

public enum SmartOrganizationGroupKind: String, Codable, Sendable {
    case category
    case nearDuplicate
    case semantic
}

/// A compact, human-facing virtual group. Relationship groups may overlap by
/// design, but Finder organization groups are mutually exclusive: one file
/// gets one primary destination proposal.
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

    /// Only category groups describe a Finder destination. Duplicate and
    /// semantic groups are evidence/navigation relationships, not move plans.
    public var canApplyToFinder: Bool { kind == .category }
}

/// Turns low-level catalog memberships and similarity components into a small
/// set of useful groups. Raw memberships remain multi-label evidence, while
/// materializable category groups choose one primary destination per file.
/// This prevents a MAT-171 PDF from being offered for MAT-171, Assignments,
/// and PDFs as three competing Finder moves.
public struct SmartOrganizationPlanner: Sendable {
    public let maxGroups: Int
    public let minimumGroupSize: Int
    public let minimumSemanticConfidence: Float

    private struct DestinationDescriptor: Sendable {
        let id: String
        let title: String
        let subtitle: String
        let priority: Int
        let members: Set<String>
    }

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
        similarityClusters: [SimilarityCluster],
        preferredCategoryByFile: [String: String] = [:]
    ) -> [SmartOrganizationGroup] {
        var membersByCategory: [String: Set<String>] = [:]
        var categoriesByFile: [String: Set<String>] = [:]
        for membership in memberships {
            let path = Self.normalize(membership.categoryPath)
            guard !path.isEmpty, !membership.fileID.isEmpty else { continue }
            membersByCategory[path, default: []].insert(membership.fileID)
            categoriesByFile[membership.fileID, default: []].insert(path)
        }

        var destinations: [DestinationDescriptor] = []
        for (path, members) in membersByCategory {
            guard members.count >= minimumGroupSize,
                  let spec = Self.categorySpec(path) else { continue }
            destinations.append(DestinationDescriptor(
                id: "category:\(path)",
                title: spec.title,
                subtitle: spec.subtitle,
                priority: spec.priority,
                members: members))
        }

        // Downloads/Desktop chaos is useful at a concept level, not one folder
        // per extension. These composite destinations participate in the same
        // primary-destination election as every other materializable group.
        let installerMembers = Self.unionMembers(
            ["Applications", "DiskImages", "Packages", "Archives"],
            from: membersByCategory)
        if installerMembers.count >= minimumGroupSize {
            destinations.append(DestinationDescriptor(
                id: "composite:installers-archives",
                title: "Installers & archives",
                subtitle: "apps, disk images & archives",
                priority: 96,
                members: installerMembers))
        }

        let mediaMembers = Self.unionMembers(["Audio", "Video"], from: membersByCategory)
        if mediaMembers.count >= minimumGroupSize {
            destinations.append(DestinationDescriptor(
                id: "composite:media",
                title: "Recordings & media",
                subtitle: "audio & video",
                priority: 92,
                members: mediaMembers))
        }

        // Highest-value specific destination wins. If assigning higher-priority
        // files causes a lower-priority folder to fall below the minimum useful
        // size, remove that folder and re-elect those files into their next-best
        // viable destination. This keeps the one-file/one-folder invariant
        // without stranding useful generic groups.
        let orderedDestinations = destinations.sorted(by: Self.destinationPrecedes)
        var choicesByFile: [String: [String]] = [:]
        for destination in orderedDestinations {
            for fileID in destination.members {
                choicesByFile[fileID, default: []].append(destination.id)
            }
        }

        // Global group priority is only a fallback. The classifier records why
        // each file received a label, so a filename-backed course, user/learned
        // correction, or specialist adjudication can outrank a generic type
        // bucket for that specific file. This is the key distinction between a
        // useful sorter and a pretty view over unordered multi-label evidence.
        for (fileID, preferredCategory) in preferredCategoryByFile {
            let preferredID = "category:\(Self.normalize(preferredCategory))"
            guard var choices = choicesByFile[fileID],
                  let index = choices.firstIndex(of: preferredID) else { continue }
            choices.remove(at: index)
            choices.insert(preferredID, at: 0)
            choicesByFile[fileID] = choices
        }

        var activeDestinationIDs = Set(orderedDestinations.map(\.id))
        var ownerByFile: [String: String] = [:]
        while true {
            ownerByFile.removeAll(keepingCapacity: true)
            var counts: [String: Int] = [:]
            for (fileID, choices) in choicesByFile {
                guard let owner = choices.first(where: { activeDestinationIDs.contains($0) }) else { continue }
                ownerByFile[fileID] = owner
                counts[owner, default: 0] += 1
            }
            let undersized = activeDestinationIDs.filter {
                counts[$0, default: 0] < minimumGroupSize
            }
            if undersized.isEmpty { break }
            activeDestinationIDs.subtract(undersized)
            if activeDestinationIDs.isEmpty {
                ownerByFile.removeAll()
                break
            }
        }

        var primaryMembersByDestination: [String: Set<String>] = [:]
        for (fileID, destinationID) in ownerByFile {
            primaryMembersByDestination[destinationID, default: []].insert(fileID)
        }

        var candidates: [(priority: Int, group: SmartOrganizationGroup)] = []
        for destination in orderedDestinations where activeDestinationIDs.contains(destination.id) {
            guard let members = primaryMembersByDestination[destination.id],
                  members.count >= minimumGroupSize else { continue }
            candidates.append((
                destination.priority,
                SmartOrganizationGroup(
                    id: destination.id,
                    title: destination.title,
                    subtitle: "\(members.count) items · \(destination.subtitle)",
                    kind: .category,
                    fileIDs: members.sorted())))
        }

        // Relationships stay useful for discovery/review, but are intentionally
        // not Finder destinations and therefore may overlap primary groups.
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
                        subtitle: "\(members.count) almost-identical files · relationship only",
                        kind: .nearDuplicate,
                        fileIDs: members,
                        confidence: Double(cluster.confidence))))
            case .semantic:
                guard members.count >= max(3, minimumGroupSize),
                      cluster.confidence >= minimumSemanticConfidence else { continue }
                let title = Self.semanticTitle(members: members, categoriesByFile: categoriesByFile)
                candidates.append((
                    85,
                    SmartOrganizationGroup(
                        id: "semantic:\(cluster.familyID)",
                        title: title,
                        subtitle: "\(members.count) related items · relationship only",
                        kind: .semantic,
                        fileIDs: members,
                        confidence: Double(cluster.confidence))))
            }
        }

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

    private static func destinationPrecedes(_ lhs: DestinationDescriptor,
                                            _ rhs: DestinationDescriptor) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.members.count != rhs.members.count { return lhs.members.count > rhs.members.count }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
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

    fileprivate static func preferredFinderCategory(
        categories: [String],
        baseCategories: [String],
        reasons: [String]
    ) -> String? {
        let base = Set(baseCategories)
        let hasSpecialist = reasons.contains { $0.hasPrefix("specialist:") }
        var best: (category: String, score: Int, priority: Int)?

        for category in categories {
            guard let spec = categorySpec(category) else { continue }
            var score = spec.priority

            // Categories added after the deterministic baseline come from a
            // learned/user correction or a schema-validated specialist. They
            // are stronger than a generic base label by design.
            if !base.contains(category) { score += 1_000 }

            if category.hasPrefix("School/") {
                let course = String(category.dropFirst("School/".count))
                if reasons.contains("filename:\(course)") { score += 700 }
                else if reasons.contains("text:\(course)") { score += 500 }
            }
            if category == "Projects/Code", reasons.contains("project:code") {
                score += 650
            }
            if category.hasPrefix("Screenshots/"),
               reasons.contains(where: { $0.hasPrefix("screenshot:") }) {
                score += 675
            }
            if category == "Assignment", reasons.contains("text:assignment-word") {
                score += 250
            }
            if hasSpecialist, !base.contains(category) { score += 250 }

            if let current = best {
                if score > current.score
                    || (score == current.score && spec.priority > current.priority)
                    || (score == current.score && spec.priority == current.priority
                        && category < current.category) {
                    best = (category, score, spec.priority)
                }
            } else {
                best = (category, score, spec.priority)
            }
        }
        return best?.category
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
    fileprivate static func categorySpec(_ path: String) ->
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
    func smartOrganizationGroups(limit: Int = 18,
                                 roots: [String]? = nil) throws -> [SmartOrganizationGroup] {
        // The Smart Groups product surface is for actionable Finder
        // organization. Similarity and duplicate relationships have dedicated
        // views and must never inherit a move button merely because the same
        // presentation type can represent them in tests/internal tooling.
        let activeIDs = Set(try allFiles(statuses: ["indexed"], roots: roots).map(\.id))
        let activeMemberships = try categoryMemberships(roots: roots).filter { activeIDs.contains($0.fileID) }

        let scope = scopedRootPredicate(column: "f.path", roots: roots)
        var clauses = ["f.status='indexed'"]
        if !scope.sql.isEmpty { clauses.append(scope.sql) }
        let rows = try query("""
            SELECT c.file_id, c.categories_json, c.base_categories_json, c.reason_codes_json
            FROM classifications c
            JOIN files f ON f.id=c.file_id
            WHERE \(clauses.joined(separator: " AND "))
            """, binds: scope.binds) { row in
                (fileID: row.text(0) ?? "",
                 categories: row.text(1) ?? "[]",
                 baseCategories: row.text(2) ?? "[]",
                 reasons: row.text(3) ?? "[]")
            }

        func decode(_ value: String) -> [String] {
            guard let data = value.data(using: .utf8),
                  let result = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return result
        }

        let exclusiveImageSubjects: Set<String> = [
            "Image/Animals", "Image/Vehicles", "Image/Scenery", "Image/Food", "Image/Documents"
        ]
        func hasUnresolvedExclusiveConflict(_ categories: [String]) -> Bool {
            let courses = categories.filter {
                $0.hasPrefix("School/") && SmartOrganizationPlanner.categorySpec($0) != nil
            }
            if Set(courses).count > 1 { return true }
            let screenshotSubtypes = categories.filter {
                $0.hasPrefix("Screenshots/") && SmartOrganizationPlanner.categorySpec($0) != nil
            }
            if Set(screenshotSubtypes).count > 1 { return true }
            if Set(categories.filter { exclusiveImageSubjects.contains($0) }).count > 1 { return true }
            return false
        }

        var preferredCategoryByFile: [String: String] = [:]
        var blockedFromFinder = Set<String>()
        for row in rows where activeIDs.contains(row.fileID) {
            let categories = decode(row.categories)
            if hasUnresolvedExclusiveConflict(categories) {
                blockedFromFinder.insert(row.fileID)
                continue
            }
            if let preferred = SmartOrganizationPlanner.preferredFinderCategory(
                categories: categories,
                baseCategories: decode(row.baseCategories),
                reasons: decode(row.reasons)) {
                preferredCategoryByFile[row.fileID] = preferred
            }
        }

        let actionableMemberships = activeMemberships.filter {
            !blockedFromFinder.contains($0.fileID)
        }
        return SmartOrganizationPlanner(maxGroups: limit).build(
            memberships: actionableMemberships,
            similarityClusters: [],
            preferredCategoryByFile: preferredCategoryByFile)
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
