#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


# Swift string/Substring compatibility in the newly-added planner.
replace_once(
    "Sources/LibrarianCore/SmartOrganization.swift",
    'return lower.prefix(1).uppercased() + lower.dropFirst()',
    'return lower.prefix(1).uppercased() + String(lower.dropFirst())',
)

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''    @Published var similarityClusters: [SimilarityCluster] = []\n    @Published var organizationGraph: OrganizationGraphSnapshot = .empty\n    @Published var coverage: OnboardingCoverage = .empty\n''',
    '''    @Published var similarityClusters: [SimilarityCluster] = []\n    @Published var organizationGraph: OrganizationGraphSnapshot = .empty\n    @Published var smartGroups: [SmartOrganizationGroup] = []\n    @Published var coverage: OnboardingCoverage = .empty\n''',
)

replace_once(
    "Sources/LibrarianApp/PrivateLibrarianApp.swift",
    '''            similarityClusters = try catalog.similarityClusters()\n            coverage = try catalog.coverage(roots: sources.map(\\.path),\n''',
    '''            similarityClusters = try catalog.similarityClusters()\n            smartGroups = try catalog.smartOrganizationGroups()\n            coverage = try catalog.coverage(roots: sources.map(\\.path),\n''',
)

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''enum LibrarySection: String, CaseIterable, Identifiable {\n    case overview\n    case screenshots\n''',
    '''enum LibrarySection: String, CaseIterable, Identifiable {\n    case overview\n    case smart\n    case screenshots\n''',
)

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''        case .overview: return "Overview"\n        case .screenshots: return "Screenshots"\n''',
    '''        case .overview: return "Overview"\n        case .smart: return "Smart Groups"\n        case .screenshots: return "Screenshots"\n''',
)

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''        case .overview: return "sparkles"\n        case .screenshots: return "camera.viewfinder"\n''',
    '''        case .overview: return "sparkles"\n        case .smart: return "sparkles.rectangle.stack"\n        case .screenshots: return "camera.viewfinder"\n''',
)

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''        case .overview:\n            OverviewView()\n        case .screenshots:\n''',
    '''        case .overview:\n            OverviewView()\n        case .smart:\n            SmartGroupsView()\n        case .screenshots:\n''',
)

replace_once(
    "Sources/LibrarianApp/MagicViews.swift",
    '''                MetricCard(title: "Graph links", value: model.dashboard.graphEdges, icon: "point.3.connected.trianglepath.dotted")\n''',
    '''                MetricCard(title: "Graph links", value: model.dashboard.graphEdges, icon: "point.3.connected.trianglepath.dotted")\n                MetricCard(title: "Smart groups", value: model.smartGroups.count, icon: "sparkles.rectangle.stack")\n''',
)

marker = '''private struct SimilarityMapView: View {\n'''
smart_view = r'''private struct SmartGroupsView: View {
    @EnvironmentObject private var model: LibrarianModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("A small set of useful virtual groups. Singleton model labels are hidden, related items are consolidated, and originals stay exactly where they are.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if model.smartGroups.isEmpty {
                ContentUnavailableView(
                    "No smart groups yet",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Index a folder first. Groups appear only when there is enough evidence to be useful."))
            } else {
                ForEach(model.smartGroups) { group in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Label(group.title, systemImage: icon(for: group.kind))
                                    .font(.headline)
                                Spacer()
                                Text("\(group.fileIDs.count) items")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(group.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if group.kind != .category {
                                Text("confidence \(String(format: "%.0f%%", group.confidence * 100))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(group.fileIDs.prefix(6)), id: \.self) { id in
                                HStack(spacing: 8) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text((model.filePath(for: id) as NSString).lastPathComponent)
                                        .lineLimit(1)
                                }
                                .font(.caption)
                            }
                            if group.fileIDs.count > 6 {
                                Text("+ \(group.fileIDs.count - 6) more")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func icon(for kind: SmartOrganizationGroupKind) -> String {
        switch kind {
        case .category: return "folder.badge.sparkles"
        case .nearDuplicate: return "square.on.square"
        case .semantic: return "point.3.connected.trianglepath.dotted"
        }
    }
}

'''
magic = Path("Sources/LibrarianApp/MagicViews.swift")
text = magic.read_text()
if text.count(marker) != 1:
    raise SystemExit("MagicViews.swift: SimilarityMapView marker not unique")
magic.write_text(text.replace(marker, smart_view + marker, 1))

print("smart groups UI patch applied")
