import Foundation
import SwiftUI
import LibrarianCore
import LibrarianAppSupport

/// One search hit. Shows where the file actually lives and offers to reveal
/// it in Finder. Note rows (path empty) render as explanatory text only.
struct SearchResultRow: View {
    @EnvironmentObject private var model: LibrarianModel
    let result: LibrarianModel.SearchResult

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                if result.path.isEmpty {
                    Text(result.modeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text((result.path as NSString).lastPathComponent)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(result.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    if !result.snippet.isEmpty {
                        Text(result.snippet)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(result.modeLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !result.path.isEmpty {
                Button {
                    model.revealInFinder(result.path)
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Reveal in Finder")
                .accessibilityLabel("Reveal in Finder")
            }
        }
        .padding(.vertical, 2)
    }

    private var iconName: String {
        if result.path.isEmpty { return "info.circle" }
        let ext = (result.path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "webp", "gif", "tiff": return "photo"
        case "mp3", "wav", "m4a", "aac", "flac": return "waveform"
        case "mp4", "mov", "mkv", "avi": return "film"
        default: return "doc"
        }
    }
}

struct LibraryStatusLine: View {
    let event: LibrarianModel.StatusEvent

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(event.message, systemImage: event.isWarning ? "exclamationmark.triangle" : "info.circle")
                .foregroundStyle(event.isWarning ? .orange : .secondary)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(event.timestamp.formatted(date: .omitted, time: .shortened))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .accessibilityLabel("at \(event.timestamp.formatted(date: .omitted, time: .shortened))")
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Latest status: \(event.message), \(event.timestamp.formatted(date: .omitted, time: .shortened))")
    }
}

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

/// The library is either an explicit aggregate of authorized roots or one
/// selected root. Keeping this as shared model state prevents the Home and
/// Library windows from displaying different meanings for the same numbers.
enum LibraryScope: Equatable, Sendable {
    case allAuthorized
    case source(UUID)
}

struct MagicContentView: View {
    private enum PendingAnalysis: Equatable {
        case all
        case source(UUID)
    }

    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.openWindow) private var openWindow
    @State private var sourcePendingRemoval: LibrarianModel.SourceFolder?
    @State private var showModelSetup = false
    @State private var pendingAnalysis: PendingAnalysis?

    private var eligibleSources: [LibrarianModel.SourceFolder] {
        model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }
    }

    private var sectionSubtitle: String {
        switch model.selectedSection {
        case .overview:
            return "A private map of your library, kept separate from your originals."
        case .smart:
            return "Curated virtual groups, ready to review without changing Finder."
        case .screenshots:
            return "Screenshot memberships from the encrypted local catalog."
        case .school:
            return "Course and assignment labels from local analysis."
        case .projects:
            return "Project labels remain virtual and source-safe."
        case .documents:
            return "Searchable text, PDF, and office evidence."
        case .media:
            return "Media labels and transcripts, kept in the encrypted catalog."
        case .similarity:
            return "Near-duplicate and semantic relationships between files."
        case .review:
            return "Low-confidence classifications waiting for your decision."
        case .duplicates:
            return "Duplicate candidates only; nothing is deleted automatically."
        case .missing:
            return "Known catalog paths; launch does not scan folders automatically."
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedSection) {
                Section("Library") {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }

                Section {
                    if model.sources.isEmpty {
                        Text("No folders authorized yet")
                            .foregroundStyle(.secondary)
                    } else {
                        Button {
                            model.selectLibraryScope(nil)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "square.grid.2x2")
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("All authorized folders")
                                    Text("Aggregate view · \(model.sources.count) folder" + (model.sources.count == 1 ? "" : "s"))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if model.libraryScope == .allAuthorized {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                        .accessibilityHidden(true)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Show the combined catalog for every authorized folder")
                        .accessibilityLabel("All authorized folders, aggregate view")
                        .listRowBackground(model.libraryScope == .allAuthorized ? Color.accentColor.opacity(0.12) : nil)

                        ForEach(model.sources) { source in
                            let name = (source.path as NSString).lastPathComponent
                            let unavailable = model.needsReauthorization(source)
                            let paused = model.isPaused(source)
                            HStack(spacing: 8) {
                                Button {
                                    model.selectLibraryScope(source)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: unavailable ? "exclamationmark.triangle.fill" : paused ? "pause.circle" : "folder.fill")
                                            .foregroundStyle(unavailable ? .orange : .secondary)
                                            .frame(width: 18)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(name.isEmpty ? source.path : name)
                                                .lineLimit(1)
                                            Text(unavailable ? "Needs permission" : paused ? "Paused" : "Ready")
                                                .font(.caption2)
                                                .foregroundStyle(unavailable || paused ? .orange : .secondary)
                                        }
                                        Spacer(minLength: 0)
                                        if model.libraryScope == .source(source.id) {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .help("Show only \(name.isEmpty ? source.path : name) in the Library")
                                .accessibilityLabel("Open \(name.isEmpty ? source.path : name) library")
                                .accessibilityHint("Filters counts, groups, review, missing, and search to this folder")
                                Spacer(minLength: 0)
                                Menu {
                                    if !unavailable {
                                        Button(paused ? "Resume analysis" : "Pause analysis") {
                                            model.togglePaused(source)
                                        }
                                    }
                                    Button("Re-authorize \(name)…") { model.reauthorizeSource(source) }
                                    Divider()
                                    Button("Remove from Library", role: .destructive) {
                                        sourcePendingRemoval = source
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .menuStyle(.borderlessButton)
                                .fixedSize()
                                .accessibilityLabel("Actions for " + (name.isEmpty ? source.path : name))
                            }
                            .padding(.vertical, 3)
                            .listRowBackground(model.libraryScope == .source(source.id) ? Color.accentColor.opacity(0.12) : nil)
                        }
                    }
                    HStack(spacing: 8) {
                        Button("Add Folder…") { model.addSourceFolder() }
                        Menu {
                            Button("Add Exclusion…") { model.addExclusionFolder() }
                            if !model.excludedPaths.isEmpty {
                                Divider()
                                ForEach(model.excludedPaths, id: \.self) { path in
                                    Button("Remove " + (path as NSString).lastPathComponent) {
                                        model.removeExclusion(path)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Manage exclusions")
                        .accessibilityLabel("Manage exclusions")
                        Spacer(minLength: 0)
                    }
                    if !model.excludedPaths.isEmpty {
                        Text(String(model.excludedPaths.count) + " exclusion" + (model.excludedPaths.count == 1 ? "" : "s") + " active")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if model.isIndexing {
                        Button("Stop Analysis") { model.cancelIndexing() }
                    } else {
                        Menu {
                            Button("Analyze all authorized folders") { requestAnalysis(nil) }
                            Divider()
                            ForEach(eligibleSources) { source in
                                let name = (source.path as NSString).lastPathComponent
                                Button("Analyze \(name.isEmpty ? source.path : name)") {
                                    requestAnalysis(source)
                                }
                            }
                        } label: {
                            Label(
                                model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "Choose what to analyze…" : "Set Up & Analyze…",
                                systemImage: model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "sparkles" : "arrow.down.circle")
                        }
                        .disabled(model.sources.isEmpty || eligibleSources.isEmpty || model.isReconciling)
                        .help(model.sources.isEmpty
                              ? "Add a folder first"
                              : (eligibleSources.isEmpty
                                 ? "All folders are paused or need permission — resume or re-authorize one"
                                 : (model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "Choose an authorized scope to read and understand without moving files"
                                    : "Set up the selected local quality level, then analyze the folder you chose")))
                    }
                } header: {
                    HStack {
                        Text("Sources")
                        Spacer()
                        Text("\(model.sources.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selectedSection.title)
                            .font(.title2.bold())
                        Text(sectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if model.selectedSection == .smart {
                        Text("\(model.smartGroups.count) groups")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)

                HStack(spacing: 8) {
                    Image(systemName: model.libraryScopeSource == nil ? "square.grid.2x2" : "folder.fill")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.libraryScopeLabel)
                            .font(.subheadline.weight(.semibold))
                        Text(model.libraryScopeDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if model.libraryScopeSource != nil {
                        Button("Show all folders") {
                            model.selectLibraryScope(nil)
                        }
                        .buttonStyle(.bordered)
                        .help("Return to the combined catalog")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 4)

                HStack(spacing: 10) {
                    TextField(model.libraryScopeSource == nil ? "Search all authorized folders…" : "Search this folder…", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                        .disabled(!model.catalogReady)
                        .accessibilityLabel("Search library")
                    Button("Search") { model.runSearch() }
                        .disabled(model.isSearching || !model.catalogReady)
                    if !model.query.isEmpty || !model.searchResults.isEmpty {
                        Button("Clear") { model.clearSearch() }
                            .keyboardShortcut(.cancelAction)
                    }
                    if model.isSearching {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Searching")
                    }
                    Button {
                        model.refreshDashboard()
                        model.refreshModelStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }.help("Refresh library status")
                        .accessibilityLabel("Refresh library status")
                }
                .padding(12)

                Divider()
                if let status = model.latestStatusEvent {
                    LibraryStatusLine(event: status)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                if model.catalogMigrationRequired {
                    CatalogMigrationBanner()
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }
                if !model.catalogReady {
                    CatalogBlockedView()
                        .padding(20)
                } else {
                    if !model.searchResults.isEmpty {
                        GroupBox("Search results for “\(model.query)” · \(model.searchResults.count)") {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                    ForEach(Array(model.searchResults.prefix(50).enumerated()), id: \.element.id) { index, result in
                                        SearchResultRow(result: result)
                                        if index < min(50, model.searchResults.count) - 1 {
                                            Divider()
                                        }
                                    }
                                    if model.searchResults.count > 50 {
                                        Text("+ \(model.searchResults.count - 50) more results — narrow the search to see them")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 6)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 240)
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    }

                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 18) {
                                Color.clear
                                    .frame(height: 1)
                                    .id("detail-top")
                                sectionBody
                            }
                            .padding(20)
                        }
                        .onAppear { proxy.scrollTo("detail-top", anchor: .top) }
                        .onChange(of: model.selectedSection) { _, _ in
                            proxy.scrollTo("detail-top", anchor: .top)
                            model.reloadSectionFiles()
                        }
                        .onChange(of: model.libraryScope) { _, _ in
                            proxy.scrollTo("detail-top", anchor: .top)
                            model.reloadSectionFiles()
                        }
                    }
                }
                Divider()
                MagicPrivacyBar(indicators: model.privacyIndicators()).padding(10)
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    openWindow(id: "main")
                } label: {
                    Label("Home", systemImage: "house")
                }
                .help("Return to the main cleanup workflow")
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear { model.start() }
        .sheet(isPresented: $showModelSetup, onDismiss: {
            if !model.isLocalModelProfileReady(model.localModelProfile) {
                pendingAnalysis = nil
            }
        }) {
            ModelSetupView(
                profile: model.localModelProfile,
                onReady: { resumePendingAnalysis() },
                onUseFast: {
                    model.localModelProfile = .fast
                    resumePendingAnalysis()
                })
                .environmentObject(model)
        }
        .confirmationDialog(
            "Remove “\(sourcePendingRemoval.map { ($0.path as NSString).lastPathComponent } ?? "")”?",
            isPresented: Binding(get: { sourcePendingRemoval != nil },
                                 set: { if !$0 { sourcePendingRemoval = nil } }),
            titleVisibility: .visible) {
            Button("Remove from Library", role: .destructive) {
                if let source = sourcePendingRemoval { model.removeSource(source) }
                sourcePendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { sourcePendingRemoval = nil }
        } message: {
            Text("The folder's files are never touched, but they disappear from search, groups, and duplicates until you add the folder again.")
        }
    }

    private func requestAnalysis(_ source: LibrarianModel.SourceFolder?) {
        guard !model.isIndexing, !model.isReconciling else { return }
        let request: PendingAnalysis = source.map { .source($0.id) } ?? .all
        if model.isLocalModelProfileReady(model.localModelProfile) {
            runAnalysis(request)
        } else {
            pendingAnalysis = request
            showModelSetup = true
        }
    }

    private func resumePendingAnalysis() {
        guard let request = pendingAnalysis else { return }
        pendingAnalysis = nil
        runAnalysis(request)
    }

    private func runAnalysis(_ request: PendingAnalysis) {
        switch request {
        case .all:
            guard !eligibleSources.isEmpty else { return }
            model.selectLibraryScope(nil)
            model.startIndexing()
        case .source(let id):
            guard let source = eligibleSources.first(where: { $0.id == id }) else { return }
            model.selectLibraryScope(source)
            model.startIndexing(source: source)
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.selectedSection {
        case .overview:
            OverviewView(onAnalyze: { requestAnalysis(nil) })
        case .smart:
            SmartGroupsView()
        case .screenshots:
            FileExplorerView(title: "Screenshot explorer", subtitle: "Images stay in place; these are catalog memberships.", files: model.sectionFiles)
        case .school:
            FileExplorerView(title: "School", subtitle: "Course and assignment labels are virtual catalog memberships.", files: model.sectionFiles)
        case .projects:
            FileExplorerView(title: "Projects", subtitle: "Project labels remain virtual and source-safe.", files: model.sectionFiles)
        case .documents:
            FileExplorerView(title: "Documents", subtitle: "Text, PDF, and office content with searchable evidence.", files: model.sectionFiles)
        case .media:
            FileExplorerView(title: "Audio & Video", subtitle: "Media remains in place; transcripts and labels stay in the encrypted catalog.", files: model.sectionFiles)
        case .similarity:
            SimilarityMapView(
                clusters: model.similarityClusters,
                filePath: { id in model.filePath(for: id) },
                previewRequest: { id in model.previewRequest(for: id) })
        case .review:
            ReviewInboxView()
        case .duplicates:
            FileExplorerView(title: "Duplicate candidates", subtitle: "Report-only results. Nothing is deleted.", files: model.sectionFiles)
        case .missing:
            MissingFilesView()
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: LibrarianModel
    let onAnalyze: () -> Void
    @State private var showRootCoverage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.dashboard.total == 0 {
                ContentUnavailableView {
                    Label("Nothing analyzed yet", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("Add a folder and run an analysis. Your files stay exactly where they are while Private Librarian builds a private, searchable map of them.")
                } actions: {
                    if model.sources.isEmpty {
                        Button("Add a Folder") { model.addSourceFolder() }
                    } else {
                        Button {
                            onAnalyze()
                        } label: {
                            Label(
                                model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "Analyze all authorized folders" : "Set Up & Analyze all authorized folders",
                                systemImage: model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "sparkles" : "arrow.down.circle")
                        }
                    }
                }
                .padding(.top, 40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
                MetricCard(title: "Cataloged", value: model.dashboard.total, icon: "books.vertical", destination: nil)
                MetricCard(title: "Indexed", value: model.dashboard.indexed, icon: "checkmark.circle", destination: nil)
                MetricCard(title: "Review", value: model.dashboard.review, icon: "questionmark.folder", destination: .review)
                MetricCard(title: "Missing", value: model.dashboard.missing, icon: "exclamationmark.triangle", destination: .missing)
                MetricCard(title: "Duplicate groups", value: model.dashboard.duplicateGroups, icon: "square.on.square", destination: .duplicates)
                MetricCard(title: "Graph links", value: model.dashboard.graphEdges, icon: "point.3.connected.trianglepath.dotted", destination: .similarity)
                MetricCard(title: "Smart groups", value: model.smartGroups.count, icon: "sparkles.rectangle.stack", destination: .smart)
            }
            HStack(spacing: 8) {
                Image(systemName: model.liveIndexRunning ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .foregroundStyle(model.liveIndexRunning ? .green : .secondary)
                Text(model.liveIndexRunning ? "Live monitoring on" : "Live monitoring off")
                if model.livePendingEvents > 0 {
                    Text("· \(model.livePendingEvents) pending").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .help(model.liveIndexRunning
                  ? "Changes in authorized folders are monitored and folded into the local catalog."
                  : "Live monitoring is off; run analysis or restore folder access to continue.")
            GroupBox("Coverage") {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: Double(model.coverage.indexedFiles), total: Double(max(1, model.coverage.catalogedFiles)))
                    Text("\(model.coverage.indexedFiles) of \(model.coverage.catalogedFiles) eligible files indexed")
                    Text("\(model.coverage.reviewFiles) need review · \(model.coverage.excludedCatalogRows) intentionally excluded catalog rows")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.coverage.roots.isEmpty {
                        DisclosureGroup(
                            "Show coverage by authorized folder (\(model.coverage.roots.count))",
                            isExpanded: $showRootCoverage) {
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
                                    .padding(.top, 4)
                                }
                            }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("What the librarian knows") {
                Text("Multiple labels, review state, similarity relationships, and missing-file history live in the encrypted catalog. Source folders stay untouched until you explicitly Apply a reviewed plan.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !model.projectSummaries.isEmpty {
                GroupBox("Project summaries") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.projectSummaries) { project in
                            Text(project.summary)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            LearnedRulesView()
        }
    }
}

private struct MetricCard: View {
    @EnvironmentObject private var model: LibrarianModel
    let title: String
    let value: Int
    let icon: String
    let destination: LibrarySection?

    @ViewBuilder
    var body: some View {
        if let destination {
            Button {
                model.selectedSection = destination
            } label: {
                cardContent
            }
            .buttonStyle(.plain)
            .help("Open \(destination.title)")
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        GroupBox {
            HStack {
                Image(systemName: icon).foregroundStyle(.tint)
                Spacer()
                Text("\(value)").font(.title.bold())
            }
            Text(title).font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private struct FileExplorerView: View {
    @EnvironmentObject private var model: LibrarianModel
    let title: String
    let subtitle: String
    let files: [Catalog.FileSummary]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
                if files.isEmpty {
                    Text("Nothing here yet — analyze an available folder to populate the view.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                                Button {
                                    model.revealInFinder(file.path)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(.borderless)
                                .disabled(file.status == "missing")
                                .help("Reveal in Finder")
                                .accessibilityLabel("Reveal in Finder")
                            }
                            .padding(.vertical, 5)
                            Divider()
                        }
                    }
                    if files.count >= 200 {
                        Text("Showing the first 200 files; run a search to find anything specific.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Label(title, systemImage: "square.grid.2x2")
                Spacer()
                Text(files.count >= 200 ? "200+ shown" : "\(files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct MissingFilesView: View {
    @EnvironmentObject private var model: LibrarianModel

    private var scopedSources: [LibrarianModel.SourceFolder] {
        if let source = model.libraryScopeSource { return [source] }
        return model.sources
    }

    private var hasCheckableSource: Bool {
        scopedSources.contains {
            !model.pausedPaths.contains($0.path)
                && !model.sourcesNeedingReauthorization.contains($0.path)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Check only when you need it")
                        .font(.headline)
                    Text(model.libraryScopeSource == nil
                         ? "This checks the catalog's known paths under authorized folders. It does not discover new files or recursively analyze folders."
                         : "This checks only known catalog paths under \(model.libraryScopeLabel). It does not discover new files or recursively analyze folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.isReconciling {
                    ProgressView("Checking known paths…")
                        .controlSize(.small)
                        .font(.caption)
                } else {
                    Button(model.libraryScopeSource == nil ? "Check known paths" : "Check this folder") {
                        model.reconcileAuthorizedSources(source: model.libraryScopeSource)
                    }
                    .disabled(model.isIndexing || !hasCheckableSource)
                    .help("Check only catalog entries already known under the currently authorized folders")
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            FileExplorerView(
                title: "Missing originals",
                subtitle: "Catalog records remain; originals are never reconstructed.",
                files: model.sectionFiles)
        }
    }
}

private struct SmartGroupsView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var groupFilter: GroupFilter = .all

    private enum GroupFilter: String, CaseIterable, Identifiable {
        case all
        case categories
        case relationships

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .categories: return "Categories"
            case .relationships: return "Relationships"
            }
        }

        func matches(_ group: SmartOrganizationGroup) -> Bool {
            switch self {
            case .all: return true
            case .categories: return group.kind == .category
            case .relationships: return group.kind != .category
            }
        }
    }

    private var visibleGroups: [SmartOrganizationGroup] {
        model.smartGroups.filter { groupFilter.matches($0) }
    }

    private var visibleItemCount: Int {
        visibleGroups.reduce(0) { $0 + $1.fileIDs.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Organize by intent")
                        .font(.headline)
                    Text("\(model.smartGroups.count) groups · \(visibleItemCount) visible memberships")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isPreparingPlan {
                    ProgressView("Preparing plan…")
                        .controlSize(.small)
                        .font(.caption)
                }
            }

            HStack(spacing: 12) {
                Picker("Show", selection: $groupFilter) {
                    ForEach(GroupFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
                Spacer()
                Text("Virtual only until you review a plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Label("Nothing moves or gets deleted from this screen. Review a plan before any Finder change.",
                  systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            if model.smartGroups.isEmpty {
                ContentUnavailableView(
                    "No smart groups yet",
                    systemImage: "sparkles.rectangle.stack",
                    description: Text("Analyze a folder first. Groups appear only when there is enough evidence to be useful."))
            } else if visibleGroups.isEmpty {
                ContentUnavailableView(
                    "No groups in this filter",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("Choose another view to see the groups already found."))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 14)], spacing: 14) {
                    ForEach(visibleGroups) { group in
                        SmartGroupCard(group: group)
                    }
                }
            }

            applyStateFooter
        }
        .sheet(item: $model.pendingApplyPlan) { plan in
            ApplyPlanConfirmationSheet(plan: plan)
        }
    }

    @ViewBuilder
    private var applyStateFooter: some View {
        if model.canUndoApply || model.lastApplyMessage != nil || model.lastApplyFailureReport != nil {
            GroupBox("Latest Finder action") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        if model.canUndoApply {
                            Button("Undo Last Apply") { model.undoLastApply() }
                                .disabled(model.isApplyOperationInProgress || model.isReconciling)
                            Text("restores \(model.undoBatchFileCount) file\(model.undoBatchFileCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if model.isApplyOperationInProgress {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Moving files…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let message = model.lastApplyMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                    }
                    if let report = model.lastApplyFailureReport {
                        DisclosureGroup {
                            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((failure.path as NSString).lastPathComponent)
                                        .font(.caption.weight(.medium))
                                    Text("\(failure.path) — \(failure.reason)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                .padding(.vertical, 2)
                            }
                        } label: {
                            Label("\(report.title) · \(report.failures.count) file\(report.failures.count == 1 ? "" : "s")", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
    }
}

private struct SmartGroupCard: View {
    @EnvironmentObject private var model: LibrarianModel
    let group: SmartOrganizationGroup

    private let previewLimit = 4
    @State private var showAllMembers = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(group.title, systemImage: icon(for: group.kind))
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text("\(group.fileIDs.count) items")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(group.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(group.kind == .category ? "Category" : "Relationship")
                    if group.kind != .category {
                        Text("confidence \(String(format: "%.0f%%", group.confidence * 100))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Divider()

                ForEach(Array(group.fileIDs.prefix(previewLimit)), id: \.self) { id in
                    let path = model.filePath(for: id)
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text((path as NSString).lastPathComponent)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .opacity(path.isEmpty ? 0.5 : 1.0)
                }
                if group.fileIDs.count > previewLimit {
                    Button("View all \(group.fileIDs.count) items") {
                        showAllMembers = true
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }

                HStack {
                    Button {
                        model.prepareApply(group: group)
                    } label: {
                        Label("Review plan", systemImage: "checklist")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Review plan for \(group.title)")
                    .disabled(!model.catalogReady || model.isPreparingPlan
                              || model.isApplyOperationInProgress || model.isReconciling)
                    .help("Preview the proposed Finder moves. Nothing changes until you confirm the plan.")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAllMembers) {
            SmartGroupMembersView(group: group)
                .environmentObject(model)
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

private struct SmartGroupMembersView: View {
    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.dismiss) private var dismiss
    let group: SmartOrganizationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.title)
                        .font(.title3.bold())
                    Text("\(group.fileIDs.count) catalog memberships · originals stay where they are")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(group.fileIDs, id: \.self) { id in
                        let path = model.filePath(for: id)
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.callout.weight(.medium))
                                Text(path.isEmpty ? "Catalog entry unavailable" : path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            if !path.isEmpty {
                                Button {
                                    model.revealInFinder(path)
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(.borderless)
                                .help("Reveal in Finder")
                                .accessibilityLabel("Reveal \((path as NSString).lastPathComponent) in Finder")
                            }
                        }
                        .padding(.vertical, 7)
                        Divider()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 680, height: 540)
    }
}

private struct ApplyPlanConfirmationSheet: View {
    @EnvironmentObject private var model: LibrarianModel
    let plan: OrganizationApplier.Plan
    @State private var selectedRootPath = ""
    @State private var excludedFileIDs: Set<String> = []
    @State private var showApplyConfirmation = false

    private var selectedCount: Int { plan.items.count - excludedFileIDs.count }

    private var rootSelection: Binding<String> {
        Binding(
            get: { selectedRootPath.isEmpty ? plan.destinationRootPath : selectedRootPath },
            set: { newRoot in
                selectedRootPath = newRoot
                // Replans swap the presented plan in place while the sheet
                // stays up; the Move button is disabled until the new preview
                // arrives so the old destination can never execute.
                model.replanApply(to: newRoot)
            })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Review “\(plan.groupTitle)”", systemImage: "folder.badge.gearshape")
                .font(.title3.bold())

            Text("This is a preview only. Nothing has moved. Check the destination and every proposed file move before applying.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if plan.candidateRootPaths.count > 1 {
                Picker("Move files into", selection: rootSelection) {
                    ForEach(plan.candidateRootPaths, id: \.self) { root in
                        Text(root).tag(root)
                    }
                }
                .disabled(model.isPreparingPlan)
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Destination folder") {
                    Text(plan.destinationFolderPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Files selected") {
                    Text("\(selectedCount)")
                }
                if plan.alreadyInPlace > 0 {
                    LabeledContent("Already in destination") {
                        Text("\(plan.alreadyInPlace) (will not move again)")
                    }
                }
                if plan.skippedOtherRoots > 0 {
                    LabeledContent("Left in other folders") {
                        Text("\(plan.skippedOtherRoots) (different authorized root)")
                    }
                }
                if !plan.missingPaths.isEmpty {
                    LabeledContent("Unavailable now") {
                        Text("\(plan.missingPaths.count) — these will stay where they are")
                    }
                }
            }
            .font(.subheadline)
            .opacity(model.isPreparingPlan ? 0.5 : 1.0)

            Text("\(selectedCount) selected file" + (selectedCount == 1 ? "" : "s") + " will move into \((plan.destinationFolderPath as NSString).lastPathComponent).")
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)

            if model.isPreparingPlan {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating preview…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if !plan.items.isEmpty {
                GroupBox("Exact moves") {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(plan.items, id: \.fileID) { item in
                                Toggle(isOn: Binding(
                                    get: { !excludedFileIDs.contains(item.fileID) },
                                    set: { included in
                                        if included {
                                            excludedFileIDs.remove(item.fileID)
                                        } else {
                                            excludedFileIDs.insert(item.fileID)
                                        }
                                    })) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text((item.fromPath as NSString).lastPathComponent)
                                            .font(.caption.weight(.medium))
                                        Text("\(item.fromPath)  →  \(item.toPath)")
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                                .toggleStyle(.checkbox)
                                if item.fileID != plan.items.last?.fileID {
                                    Divider()
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .frame(maxHeight: 230)
                }
            }

            Text("Files are moved, never copied or deleted. The planned names above are reserved to avoid overwriting existing files. The operation is journaled so Undo can restore successful moves.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(excludedFileIDs.isEmpty
                     ? "Nothing excluded"
                     : "\(excludedFileIDs.count) excluded")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { model.cancelApply() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply plan · \(selectedCount) file" + (selectedCount == 1 ? "" : "s")) {
                    showApplyConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || model.isPreparingPlan)
                .accessibilityLabel("Apply plan for \(plan.groupTitle), \(selectedCount) file" + (selectedCount == 1 ? "" : "s"))
            }
        }
        .padding(24)
        .frame(width: 620)
        .onAppear { selectedRootPath = plan.destinationRootPath }
        .onChange(of: plan.id) { _, _ in
            // A replan replaces the plan items; exclusions that no longer
            // match an item in the new plan would silently skew every count.
            excludedFileIDs.formIntersection(Set(plan.items.map(\.fileID)))
        }
        .confirmationDialog(
            "Apply “\(plan.groupTitle)” plan?",
            isPresented: $showApplyConfirmation,
            titleVisibility: .visible) {
                Button("Move \(selectedCount) file" + (selectedCount == 1 ? "" : "s"), role: .destructive) {
                    model.confirmApply(excluding: excludedFileIDs)
                    showApplyConfirmation = false
                }
                Button("Keep reviewing", role: .cancel) { showApplyConfirmation = false }
            } message: {
                Text("The selected originals will move into \(plan.destinationFolderPath). Nothing will be copied or deleted, and successful moves can be undone.")
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
                    Text("Families will appear after analysis and refreshing.").foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
    @State private var rulePendingDeletion: LearnedRule?

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
                            Button { rulePendingDeletion = rule } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete rule…")
                            .accessibilityLabel("Delete learned rule \(rule.targetCategory)")
                        }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog(
            "Delete this learned rule?",
            isPresented: Binding(
                get: { rulePendingDeletion != nil },
                set: { if !$0 { rulePendingDeletion = nil } }),
            titleVisibility: .visible) {
                Button("Delete rule", role: .destructive) {
                    if let rulePendingDeletion {
                        model.deleteLearnedRule(rulePendingDeletion)
                    }
                    rulePendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { rulePendingDeletion = nil }
            } message: {
                Text("This removes the catalog rule and stops it from influencing future analysis. Existing files are not changed.")
            }
    }
}

private struct ReviewInboxView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var categoryDrafts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uncertain classifications stay here until you correct or resolve them.")
                .font(.caption).foregroundStyle(.secondary)
            if model.reviewItems.isEmpty {
                ContentUnavailableView("Inbox clear", systemImage: "checkmark.seal", description: Text("No low-confidence items are waiting."))
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.reviewItems) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text((item.path as NSString).lastPathComponent).font(.headline)
                                    Spacer()
                                    Text(String(format: "%.0f%%", item.confidence * 100)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(item.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                Text("Why this needs review: \(humanReasons(item.reasonCodes))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    TextField("Category to add or remove", text: Binding(
                                        get: { categoryDrafts[item.fileID] ?? "" },
                                        set: { categoryDrafts[item.fileID] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                    if let candidate = item.categories.first {
                                        Button("Accept suggested category") {
                                            apply(item: item, category: candidate, action: .addCategory)
                                        }
                                        .help("Add the suggested category \(candidate)")
                                    }
                                    Button("Add category") {
                                        let name = (categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        apply(item: item, category: name, action: .addCategory)
                                    }
                                    .disabled((categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                        .help("Type a category name first")
                                    Button("Remove category") {
                                        let name = (categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        apply(item: item, category: name, action: .removeCategory)
                                    }
                                    .disabled((categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                        .help("Type the category to remove first")
                                    Button("Mark as unknown") { apply(item: item, category: "", action: .markUnknown) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func apply(item: ReviewItem, category: String, action: ReviewCorrectionAction) {
        model.applyReviewCorrection(item: item, category: category, action: action)
        categoryDrafts.removeValue(forKey: item.fileID)
    }

    private func humanReasons(_ codes: [String]) -> String {
        guard !codes.isEmpty else { return "the classifier did not find enough evidence" }
        return codes.map { code in
            switch code {
            case "weak-signal": return "not enough evidence"
            case "unknown": return "no confident category"
            case "strong-signal": return "conflicting evidence"
            default: return code.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }.joined(separator: " · ")
    }
}

private struct CatalogBlockedView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var recoveryAction: CatalogRecoveryAction?

    var body: some View {
        ContentUnavailableView {
            Label("Catalog is not open", systemImage: "lock.doc")
        } description: {
            if model.catalogMigrationRequired {
                Text("The existing encrypted catalog is waiting for the one-time migration action above. No library results are shown until it opens.")
            } else if let error = model.catalogError, !error.isEmpty {
                Text("The catalog could not be opened: \(error)")
            } else {
                Text("The encrypted catalog is still opening. Try again if this message remains.")
            }
        } actions: {
            if !model.catalogMigrationRequired {
                Button("Retry Catalog") { model.retryCatalogOpen() }
                if model.catalogError != nil {
                    Button("Move blocked library aside…") { recoveryAction = .resetKey }
                        .help("Move the unreadable encrypted catalog aside without deleting it, then create a new one")
                }
            } else if !model.catalogMigrationAttempted {
                Button("Start empty catalog…") { recoveryAction = .startFresh }
                    .help("Keep the existing encrypted library on disk and open a new empty catalog")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .confirmationDialog(
            recoveryAction?.title ?? "Catalog recovery",
            isPresented: Binding(
                get: { recoveryAction != nil },
                set: { if !$0 { recoveryAction = nil } }),
            titleVisibility: .visible) {
                switch recoveryAction {
                case .startFresh:
                    Button("Start empty catalog", role: .destructive) {
                        model.startFreshCatalog()
                        recoveryAction = nil
                    }
                case .resetKey:
                    Button("Move old catalog aside and continue", role: .destructive) {
                        model.resetCatalogKeyAndStartFresh()
                        recoveryAction = nil
                    }
                case nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) { recoveryAction = nil }
            } message: {
                switch recoveryAction {
                case .startFresh:
                    Text("The existing encrypted catalog will stay on disk, but this app will open a new empty catalog. Your source files are not touched.")
                case .resetKey:
                    Text("The unreadable catalog and its key will be moved aside, never deleted. A new encrypted catalog will be created.")
                case nil:
                    Text("")
                }
            }
    }
}

private struct CatalogMigrationBanner: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var recoveryAction: CatalogRecoveryAction?

    var body: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "key.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("One-time catalog migration required")
                        .font(.headline)
                    Text("Private Librarian found an older encrypted library. Migrate it once, or start a separate empty catalog without changing source files. The existing catalog is never overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.catalogMigrationAttempted ? "Migration attempted" : "Migrate existing library") {
                            model.migrateCatalog()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.catalogMigrationAttempted)
                        .accessibilityHint("Reads the older catalog once and does not modify source files")
                        if !model.catalogMigrationAttempted {
                            Button("Start empty catalog…") { recoveryAction = .startFresh }
                            .buttonStyle(.bordered)
                            .help("Your existing library will no longer open in the app (it stays safe on disk). Use only when you know you want a blank start.")
                            .accessibilityHint("Creates a separate encrypted catalog and leaves the existing catalog untouched")
                        }
                    }
                    if model.catalogMigrationAttempted {
                        Text("If the one-time migration was denied, reopen the app and retry it. Normal launches do not need this migration step.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .tint(.orange)
        .confirmationDialog(
            recoveryAction?.title ?? "Catalog recovery",
            isPresented: Binding(
                get: { recoveryAction != nil },
                set: { if !$0 { recoveryAction = nil } }),
            titleVisibility: .visible) {
                Button("Start empty catalog", role: .destructive) {
                    model.startFreshCatalog()
                    recoveryAction = nil
                }
                Button("Cancel", role: .cancel) { recoveryAction = nil }
            } message: {
                Text("The existing encrypted catalog will stay on disk, but this app will open a new empty catalog. Your source files are not touched.")
            }
    }
}

private struct MagicPrivacyBar: View {
    let indicators: [(String, Bool)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)],
                alignment: .leading,
                spacing: 6) {
                ForEach(indicators, id: \.0) { item in
                    Label(item.0, systemImage: item.1 ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(item.1 ? .green : .red)
                        .font(.caption)
                }
            }
            Text("Local · encrypted · originals move only after you apply a reviewed plan")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
