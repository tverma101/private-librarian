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
    private enum PendingAnalysis: Equatable {
        case all
        case source(UUID)
    }

    @EnvironmentObject private var model: LibrarianModel
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
            return "Catalog records whose originals are no longer available."
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
                        ForEach(model.sources) { source in
                            let name = (source.path as NSString).lastPathComponent
                            let unavailable = model.needsReauthorization(source)
                            let paused = model.isPaused(source)
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
                                .help(source.path)
                                Spacer(minLength: 0)
                                Menu {
                                    if !unavailable {
                                        Button(paused ? "Resume analysis" : "Pause analysis") {
                                            model.togglePaused(source)
                                        }
                                    }
                                    Button("Re-authorize…") { model.reauthorizeSource(source) }
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
                            Button("All Authorized Folders") { requestAnalysis(nil) }
                            Divider()
                            ForEach(eligibleSources) { source in
                                let name = (source.path as NSString).lastPathComponent
                                Button(name.isEmpty ? source.path : name) {
                                    requestAnalysis(source)
                                }
                            }
                        } label: {
                            Label(
                                model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "Analyze" : "Set Up & Analyze",
                                systemImage: model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "sparkles" : "arrow.down.circle")
                        }
                        .disabled(model.sources.isEmpty || eligibleSources.isEmpty || model.isReconciling)
                        .help(model.sources.isEmpty
                              ? "Add a folder first"
                              : (eligibleSources.isEmpty
                                 ? "All folders are paused or need permission — resume or re-authorize one"
                                 : (model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "Read and understand files without moving them"
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
                            .lineLimit(1)
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

                HStack(spacing: 10) {
                    TextField("Search everything…", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                        .disabled(!model.catalogReady)
                        .accessibilityLabel("Search library")
                    Button("Search") { model.runSearch() }
                        .disabled(model.isSearching || !model.catalogReady)
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
                if let latestStatus = model.statusLines.last {
                    Label(latestStatus,
                          systemImage: latestStatus.localizedCaseInsensitiveContains("error")
                            ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(latestStatus.localizedCaseInsensitiveContains("error") ? .orange : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .textSelection(.enabled)
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
                        GroupBox("Search results · \(model.searchResults.count)") {
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
                    }
                }
                Divider()
                MagicPrivacyBar(indicators: model.privacyIndicators()).padding(10)
            }
        }
        .toolbar {
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
            model.startIndexing()
        case .source(let id):
            guard let source = eligibleSources.first(where: { $0.id == id }) else { return }
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
            FileExplorerView(title: "Missing originals", subtitle: "Catalog records remain; originals are never reconstructed.", files: model.sectionFiles)
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var model: LibrarianModel
    let onAnalyze: () -> Void

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
                                    ? "Analyze Folders" : "Set Up & Analyze",
                                systemImage: model.isLocalModelProfileReady(model.localModelProfile)
                                    ? "sparkles" : "arrow.down.circle")
                        }
                    }
                }
                .padding(.top, 40)
            }
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
                Text("\(files.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
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
                    HStack(spacing: 8) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                        Text((model.filePath(for: id) as NSString).lastPathComponent)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .opacity(model.filePath(for: id).isEmpty ? 0.5 : 1.0)
                }
                if group.fileIDs.count > previewLimit {
                    Text("+ \(group.fileIDs.count - previewLimit) more · search above to find them")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Button {
                        model.prepareApply(group: group)
                    } label: {
                        Label("Review plan", systemImage: "checklist")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!model.catalogReady || model.isPreparingPlan
                              || model.isApplyOperationInProgress || model.isReconciling)
                    .help("Preview the proposed Finder moves. Nothing changes until you confirm the plan.")
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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

private struct ApplyPlanConfirmationSheet: View {
    @EnvironmentObject private var model: LibrarianModel
    let plan: OrganizationApplier.Plan
    @State private var selectedRootPath = ""
    @State private var excludedFileIDs: Set<String> = []

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
                Button("Move \(selectedCount) Files") {
                    model.confirmApply(excluding: excludedFileIDs)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || model.isPreparingPlan)
                .keyboardShortcut(.defaultAction)
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
                                Text(item.reasonCodes.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                HStack {
                                    TextField("Category", text: Binding(
                                        get: { categoryDrafts[item.fileID] ?? "" },
                                        set: { categoryDrafts[item.fileID] = $0 }))
                                        .textFieldStyle(.roundedBorder)
                                    if let candidate = item.categories.first {
                                        Button("Accept \(candidate)") {
                                            apply(item: item, category: candidate, action: .addCategory)
                                        }
                                    }
                                    Button("Add") {
                                        let name = (categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        apply(item: item, category: name, action: .addCategory)
                                    }
                                    .disabled((categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                    .help("Type a category name first")
                                    Button("Remove") {
                                        let name = (categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces)
                                        guard !name.isEmpty else { return }
                                        apply(item: item, category: name, action: .removeCategory)
                                    }
                                    .disabled((categoryDrafts[item.fileID] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                                    .help("Type the category to remove first")
                                    Button("Unknown") { apply(item: item, category: "", action: .markUnknown) }
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
}

private struct CatalogBlockedView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var confirmReset = false
    @State private var confirmStartFresh = false

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
                    Button(confirmReset ? "Confirm: Lock Old Catalog Aside and Start Fresh" : "Key Still Blocked? Reset Catalog Key…") {
                        if confirmReset {
                            model.resetCatalogKeyAndStartFresh()
                            confirmReset = false
                        } else {
                            confirmReset = true
                        }
                    }
                    .foregroundStyle(.red)
                    .help("Moves the old encrypted catalog files aside (they are never deleted), removes the unreadable key, and creates a new encrypted catalog. Use this when every launch asks for keychain access and then fails.")
                }
            } else if !model.catalogMigrationAttempted {
                Button(confirmStartFresh
                       ? "Confirm: Switch to an Empty Catalog"
                       : "Start New Catalog") {
                    if confirmStartFresh {
                        model.startFreshCatalog()
                        confirmStartFresh = false
                    } else {
                        confirmStartFresh = true
                    }
                }
                .help("Your existing library will no longer open in the app (it stays safe on disk). Use only when you know you want a blank start.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CatalogMigrationBanner: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var confirmStartFresh = false

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
                    Text("Private Librarian found an existing encrypted catalog. Migrate it with one macOS Keychain approval, or start a separate fresh catalog without approval. The existing catalog is never overwritten.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button(model.catalogMigrationAttempted ? "Migration attempted" : "Migrate Existing Catalog") {
                            model.migrateCatalog()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.catalogMigrationAttempted)
                        .accessibilityHint("Reads the legacy catalog key once and does not modify source files")
                        if !model.catalogMigrationAttempted {
                            Button(confirmStartFresh ? "Confirm: Switch to an Empty Catalog" : "Start New Catalog") {
                                if confirmStartFresh {
                                    model.startFreshCatalog()
                                    confirmStartFresh = false
                                } else {
                                    confirmStartFresh = true
                                }
                            }
                            .buttonStyle(.bordered)
                            .help("Your existing library will no longer open in the app (it stays safe on disk). Use only when you know you want a blank start.")
                            .accessibilityHint("Creates a separate encrypted catalog and leaves the existing catalog untouched")
                        }
                    }
                    if model.catalogMigrationAttempted {
                        Text("If access was denied, relaunch and try again after choosing Always Allow.")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .tint(.orange)
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
            Text("LOCAL · ENCRYPTED · MOVES ONLY WHEN YOU APPLY")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
