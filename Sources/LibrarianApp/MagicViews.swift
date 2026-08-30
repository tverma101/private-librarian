import Foundation
import SwiftUI
import LibrarianCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case overview
    case smart
    case screenshots
    case school
    case projects
    case documents
    case media
    case similarity
    case review
    case duplicates
    case missing

    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .smart: return "Smart Groups"
        case .screenshots: return "Screenshots"
        case .school: return "School"
        case .projects: return "Projects"
        case .documents: return "Documents"
        case .media: return "Audio & Video"
        case .similarity: return "Similarity Map"
        case .review: return "Review Inbox"
        case .duplicates: return "Duplicates"
        case .missing: return "Missing"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "sparkles"
        case .smart: return "sparkles.rectangle.stack"
        case .screenshots: return "camera.viewfinder"
        case .school: return "graduationcap"
        case .projects: return "folder.badge.gearshape"
        case .documents: return "doc.text"
        case .media: return "waveform"
        case .similarity: return "point.3.connected.trianglepath.dotted"
        case .review: return "questionmark.folder"
        case .duplicates: return "square.on.square"
        case .missing: return "exclamationmark.triangle"
        }
    }
}

struct MagicContentView: View {
    @EnvironmentObject private var model: LibrarianModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Section("Magic Library") {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }

                Section("Sources · read-only") {
                    if model.sources.isEmpty {
                        Text("No folders authorized").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.sources) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Label((source.path as NSString).lastPathComponent.isEmpty
                                          ? source.path : (source.path as NSString).lastPathComponent,
                                          systemImage: model.isPaused(source) ? "pause.circle" : "folder")
                                    Spacer()
                                    Button { model.togglePaused(source) } label: {
                                        Image(systemName: model.isPaused(source) ? "play" : "pause")
                                    }.buttonStyle(.borderless)
                                        .accessibilityLabel(model.isPaused(source) ? "Resume source" : "Pause source")
                                    Button { model.reauthorizeSource(source) } label: {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }.buttonStyle(.borderless)
                                        .help("Re-authorize folder")
                                        .accessibilityLabel("Re-authorize folder")
                                    Button { model.removeSource(source) } label: {
                                        Image(systemName: "trash")
                                    }.buttonStyle(.borderless)
                                        .help("Remove root from the catalog view")
                                        .accessibilityLabel("Remove source from catalog")
                                }
                                Text(source.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if model.needsReauthorization(source) {
                                    Text("Needs reauthorization — indexing is paused for this folder")
                                        .font(.caption2).foregroundStyle(.orange)
                                } else if model.isPaused(source) {
                                    Text("Paused — originals remain untouched")
                                        .font(.caption2).foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                    Button("Add Folder…") { model.addSourceFolder() }
                    Button("Add Exclusion…") { model.addExclusionFolder() }
                    ForEach(model.excludedPaths, id: \.self) { path in
                        HStack {
                            Label((path as NSString).lastPathComponent, systemImage: "eye.slash")
                            Spacer()
                            Button { model.removeExclusion(path) } label: {
                                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                            }.buttonStyle(.borderless)
                                .accessibilityLabel("Remove exclusion")
                        }
                    }
                    if model.isIndexing {
                        Button("Stop Cleanup") { model.cancelIndexing() }
                    } else {
                        Menu("Clean Up") {
                            Button("All Authorized Folders") { model.startIndexing() }
                            Divider()
                            ForEach(model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }) { source in
                                let name = (source.path as NSString).lastPathComponent
                                Button("Only \(name.isEmpty ? source.path : name)") {
                                    model.startIndexing(source: source)
                                }
                            }
                        }
                        .disabled(model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) || model.needsReauthorization($0) })
                    }
                }

                Section("Settings") {
                    Toggle("Local embeddings", isOn: $model.localEmbeddingsEnabled)
                        .help(model.isTier2Provisioned ? "On-device only — no network" : "Provision Models/ first")
                        .disabled(!model.isTier2Provisioned)
                    Picker("Model profile", selection: $model.localModelProfile) {
                        Text("Fast · embeddings only").tag(LocalModelProfile.fast)
                        Text("Balanced · specialist fallback").tag(LocalModelProfile.balanced)
                        Text("Quality · heavy fallback allowed").tag(LocalModelProfile.quality)
                    }
                    .pickerStyle(.menu)
                    .help("Models are local-only and never downloaded automatically. Heavy models run only on ambiguous files.")
                    Toggle("Local transcription", isOn: $model.localTranscriptionEnabled)
                        .help("Opt-in whisper.cpp transcription. Nothing is downloaded automatically.")
                        .disabled(!model.isLocalTranscriptionAvailable)
                    Text(model.localTranscriptionStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Picker("Search", selection: $model.searchMode) {
                        Text("Auto").tag("auto")
                        Text("Exact").tag("exact")
                        Text("Semantic").tag("semantic")
                        Text("CLIP text→image").tag("clipText")
                    }
                    .pickerStyle(.menu)
                    .onChange(of: model.searchMode) { _, value in
                        UserDefaults.standard.set(value, forKey: "tier2-search-mode-v1")
                    }
                    Text(model.isTier2Provisioned ? "Tier-2 ready" : "Tier-2 not provisioned")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TextField("Search everything…", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                    Button("Search") { model.runSearch() }
                    Button { model.refreshDashboard() } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Refresh catalog dashboard")
                        .accessibilityLabel("Refresh catalog dashboard")
                }
                .padding(12)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text(model.selectedSection.title).font(.title2.bold())
                            Spacer()
                            Text("virtual · offline · read-only")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        sectionBody
                    }
                    .padding(20)
                }
                Divider()
                MagicPrivacyBar(indicators: model.privacyIndicators()).padding(10)
            }
        }
        .onAppear { model.refreshDashboard() }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.selectedSection {
        case .overview:
            OverviewView()
        case .smart:
            SmartGroupsView()
        case .screenshots:
            FileExplorerView(title: "Screenshot explorer", subtitle: "Images stay in place; these are catalog memberships.", files: model.files(for: .screenshots))
        case .school:
            FileExplorerView(title: "School", subtitle: "Course and assignment labels are virtual catalog memberships.", files: model.files(for: .school))
        case .projects:
            FileExplorerView(title: "Projects", subtitle: "Project labels remain virtual and source-safe.", files: model.files(for: .projects))
        case .documents:
            FileExplorerView(title: "Documents", subtitle: "Text, PDF, and office content with searchable evidence.", files: model.files(for: .documents))
        case .media:
            FileExplorerView(title: "Audio & Video", subtitle: "Media remains in place; transcripts and labels stay in the encrypted catalog.", files: model.files(for: .media))
        case .similarity:
            SimilarityMapView(
                clusters: model.similarityClusters,
                filePath: { id in model.filePath(for: id) },
                previewRequest: { id in model.previewRequest(for: id) })
        case .review:
            ReviewInboxView()
        case .duplicates:
            FileExplorerView(title: "Duplicate candidates", subtitle: "Report-only results. Nothing is deleted.", files: model.files(for: .duplicates))
        case .missing:
            FileExplorerView(title: "Missing originals", subtitle: "Catalog records remain; originals are never reconstructed.", files: model.files(for: .missing))
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: LibrarianModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                MetricCard(title: "Cataloged", value: model.dashboard.total, icon: "books.vertical")
                MetricCard(title: "Indexed", value: model.dashboard.indexed, icon: "checkmark.circle")
                MetricCard(title: "Review", value: model.dashboard.review, icon: "questionmark.folder")
                MetricCard(title: "Missing", value: model.dashboard.missing, icon: "exclamationmark.triangle")
                MetricCard(title: "Duplicate groups", value: model.dashboard.duplicateGroups, icon: "square.on.square")
                MetricCard(title: "Graph links", value: model.dashboard.graphEdges, icon: "point.3.connected.trianglepath.dotted")
                MetricCard(title: "Smart groups", value: model.smartGroups.count, icon: "sparkles.rectangle.stack")
            }
            HStack(spacing: 8) {
                Image(systemName: model.liveIndexRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(model.liveIndexRunning ? .green : .secondary)
                Text(model.liveIndexRunning ? "Live indexing on" : "Live indexing unavailable")
                if model.livePendingEvents > 0 {
                    Text("· \(model.livePendingEvents) pending").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            GroupBox("Coverage") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(model.coverage.indexedFiles), total: Double(max(1, model.coverage.catalogedFiles)))
                    Text("\(model.coverage.indexedFiles) of \(model.coverage.catalogedFiles) eligible files indexed")
                    Text("\(model.coverage.reviewFiles) need review · \(model.coverage.excludedCatalogRows) intentionally excluded catalog rows")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(model.coverage.roots) { root in
                        VStack(alignment: .leading, spacing: 2) {
                            Text((root.root as NSString).lastPathComponent.isEmpty
                                 ? root.root : (root.root as NSString).lastPathComponent)
                                .font(.caption.bold())
                            Text("\(root.indexedFiles)/\(root.eligibleFiles) indexed · \(root.reviewFiles) review · \(root.missingFiles) missing · \(root.skippedFiles) skipped")
                                .font(.caption2).foregroundStyle(.secondary)
                            if !root.exclusionReasons.isEmpty {
                                Text(root.exclusionReasons.keys.sorted().map {
                                    "\($0) \(root.exclusionReasons[$0] ?? 0)"
                                }.joined(separator: " · "))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("What the librarian knows") {
                Text("Multiple labels, review state, similarity relationships, and missing-file history live in the encrypted catalog. The source folders remain untouched.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.searchResults.isEmpty {
                GroupBox("Search results") {
                    ForEach(model.searchResults, id: \.self) { Text($0).textSelection(.enabled) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LearnedRulesView()
        }
    }
}

private struct MetricCard: View {
    let title: String
    let value: Int
    let icon: String

    var body: some View {
        GroupBox {
            HStack {
                Image(systemName: icon).foregroundStyle(.tint)
                Spacer()
                Text("\(value)").font(.title.bold())
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FileExplorerView: View {
    let title: String
    let subtitle: String
    let files: [Catalog.FileSummary]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if files.isEmpty {
                    Text("Nothing here yet — index an authorized folder to populate the view.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(files) { file in
                        HStack {
                            Image(systemName: file.status == "missing" ? "exclamationmark.triangle" : "doc")
                                .foregroundStyle(file.status == "missing" ? .orange : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((file.path as NSString).lastPathComponent).lineLimit(1)
                                Text(file.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if let confidence = file.confidence {
                                Text(String(format: "%.0f%%", confidence * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label(title, systemImage: "square.grid.2x2")
        }
    }
}

private struct SmartGroupsView: View {
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

private struct SimilarityMapView: View {
    let clusters: [SimilarityCluster]
    let filePath: (String) -> String
    let previewRequest: (String) -> LibrarianModel.PreviewRequest?
    @State private var expandedClusterIDs: Set<String> = []

    var body: some View {
        GroupBox("Similarity families") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Near-duplicate and semantic families are virtual catalog relationships. Files are not moved or renamed.")
                    .font(.caption).foregroundStyle(.secondary)
                if clusters.isEmpty {
                    Text("Families will appear after indexing and refreshing.").foregroundStyle(.secondary)
                } else {
                    ForEach(clusters, id: \.id) { cluster in
                        DisclosureGroup(isExpanded: expandedBinding(for: cluster.id)) {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 10) {
                                    RepresentativeThumbnailView(
                                        request: previewRequest(cluster.representative),
                                        fallbackSymbol: cluster.relation == .nearDuplicate
                                            ? "photo.stack" : "square.stack.3d.up")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Representative")
                                            .font(.caption.bold())
                                        Text(filePath(cluster.representative))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Text("Reason: \(cluster.reason) · confidence \(String(format: "%.0f%%", cluster.confidence * 100))")
                                    .font(.caption2).foregroundStyle(.secondary)
                                ForEach(cluster.members, id: \.self) { member in
                                    HStack(spacing: 8) {
                                        Image(systemName: member == cluster.representative
                                              ? "star.fill" : "photo")
                                            .foregroundStyle(member == cluster.representative ? .yellow : .secondary)
                                        Text(filePath(member))
                                            .font(.caption2)
                                            .lineLimit(2)
                                        if member == cluster.representative {
                                            Text("representative")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            HStack {
                                Image(systemName: cluster.relation == .nearDuplicate
                                      ? "square.on.square" : "point.3.connected.trianglepath.dotted")
                                    .foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cluster.relation == .nearDuplicate
                                         ? "Near-duplicate family" : "Semantic cluster")
                                        .font(.headline)
                                    Text("\(cluster.members.count) members · \(cluster.reason)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.0f%%", cluster.confidence * 100))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func expandedBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { expandedClusterIDs.contains(id) },
            set: { isExpanded in
                if isExpanded {
                    expandedClusterIDs.insert(id)
                } else {
                    expandedClusterIDs.remove(id)
                }
            })
    }
}

private struct RepresentativeThumbnailView: View {
    let request: LibrarianModel.PreviewRequest?
    let fallbackSymbol: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 56, height: 44)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Representative preview")
        .task(id: request) {
            guard let request else { return }
            let data = await Task.detached(priority: .utility) {
                LibrarianModel.previewData(request)
            }.value
            guard let data else { return }
            image = NSImage(data: data)
        }
    }
}

private struct LearnedRulesView: View {
    @EnvironmentObject private var model: LibrarianModel

    var body: some View {
        GroupBox("Learned rules") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Rules are catalog-only, inspectable, reversible, and disabled until you enable them.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.learnedRules.isEmpty {
                    Text("No repeated correction pattern has been promoted yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.learnedRules, id: \.id) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(rule.patternType.rawValue): \(rule.pattern) → \(rule.targetCategory)")
                                    .lineLimit(1)
                                Text("confidence \(String(format: "%.0f%%", rule.confidence * 100)) · \(rule.provenance)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { rule.enabled },
                                set: { _ in model.toggleLearnedRule(rule) }
                            ))
                            .toggleStyle(.checkbox)
                            Button { model.deleteLearnedRule(rule) } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete rule")
                            .accessibilityLabel("Delete learned rule")
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ReviewInboxView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var category = "Review/Confirmed"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uncertain classifications stay here until you correct or resolve them.")
                .font(.caption).foregroundStyle(.secondary)
            if model.reviewItems.isEmpty {
                ContentUnavailableView("Inbox clear", systemImage: "checkmark.seal", description: Text("No low-confidence items are waiting."))
            } else {
                ForEach(model.reviewItems) { item in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text((item.path as NSString).lastPathComponent).font(.headline)
                                Spacer()
                                Text(String(format: "%.0f%%", item.confidence * 100)).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Text(item.reasonCodes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                TextField("Category", text: $category).textFieldStyle(.roundedBorder)
                                if let candidate = item.categories.first {
                                    Button("Accept \(candidate)") {
                                        model.applyReviewCorrection(item: item, category: candidate, action: .addCategory)
                                    }
                                }
                                Button("Add") { model.applyReviewCorrection(item: item, category: category, action: .addCategory) }
                                Button("Remove") { model.applyReviewCorrection(item: item, category: category, action: .removeCategory) }
                                Button("Unknown") { model.applyReviewCorrection(item: item, category: "", action: .markUnknown) }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct MagicPrivacyBar: View {
    let indicators: [(String, Bool)]

    var body: some View {
        HStack(spacing: 10) {
            ForEach(indicators, id: \.0) { item in
                Label(item.0, systemImage: item.1 ? "checkmark.seal.fill" : "xmark.seal.fill")
                    .foregroundStyle(item.1 ? .green : .red)
                    .font(.caption)
            }
            Spacer()
            Text("READ ONLY · OFFLINE · ENCRYPTED").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
