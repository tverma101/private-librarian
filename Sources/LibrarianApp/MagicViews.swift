import Foundation
import SwiftUI
import LibrarianCore

enum LibrarySection: String, CaseIterable, Identifiable {
    case overview
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
                                    Label((source.path as NSString).lastPathComponent,
                                          systemImage: model.isPaused(source) ? "pause.circle" : "folder")
                                    Spacer()
                                    Button { model.togglePaused(source) } label: {
                                        Image(systemName: model.isPaused(source) ? "play" : "pause")
                                    }.buttonStyle(.borderless)
                                    Button { model.reauthorizeSource(source) } label: {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                    }.buttonStyle(.borderless).help("Re-authorize folder")
                                    Button { model.removeSource(source) } label: {
                                        Image(systemName: "trash")
                                    }.buttonStyle(.borderless).help("Remove root from the catalog view")
                                }
                                Text(source.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                if model.isPaused(source) {
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
                        }
                    }
                    Button(model.isIndexing ? "Indexing…" : "Index Now") { model.startIndexing() }
                        .disabled(model.isIndexing || model.sources.isEmpty || model.sources.allSatisfy { model.isPaused($0) })
                }

                Section("Settings") {
                    Toggle("Local embeddings", isOn: $model.localEmbeddingsEnabled)
                        .help(model.isTier2Provisioned ? "On-device only — no network" : "Provision Models/ first")
                        .disabled(!model.isTier2Provisioned)
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
            SimilarityMapView(snapshot: model.organizationGraph)
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
            }
            GroupBox("Coverage") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(model.coverage.indexedFiles), total: Double(max(1, model.coverage.catalogedFiles)))
                    Text("\(model.coverage.indexedFiles) of \(model.coverage.catalogedFiles) eligible files indexed")
                    Text("\(model.coverage.reviewFiles) need review · \(model.coverage.excludedCatalogRows) intentionally excluded catalog rows")
                        .font(.caption).foregroundStyle(.secondary)
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

private struct SimilarityMapView: View {
    let snapshot: OrganizationGraphSnapshot

    var body: some View {
        GroupBox("Organization graph") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Virtual relationships only. Files are not moved or renamed.")
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.edges.isEmpty {
                    Text("Graph will appear after indexing and refreshing.").foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.edges.prefix(120), id: \.self) { edge in
                        HStack {
                            Text(edge.sourceID).font(.caption.monospaced()).lineLimit(1)
                            Image(systemName: "arrow.right").foregroundStyle(.secondary)
                            Text(edge.targetID).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(edge.relation.rawValue).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
                                Button("Add") { model.applyReviewCorrection(item: item, category: category, action: .addCategory) }
                                Button("Remove") { model.applyReviewCorrection(item: item, category: category, action: .removeCategory) }
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
