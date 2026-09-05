import SwiftUI
import LibrarianCore

enum CatalogRecoveryAction: String, Identifiable {
    case startFresh
    case resetKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .startFresh: return "Start with an empty catalog?"
        case .resetKey: return "Create a new encrypted catalog?"
        }
    }
}

/// The default product surface: one cleanup action, a small amount of state,
/// and progressive disclosure into the advanced catalog when the user asks.
/// Analysis is read-only; Finder changes happen only through the separately
/// reviewed and journaled Apply workflow.
struct CleanerHomeView: View {
    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSourceID: UUID?
    @State private var catalogRecoveryAction: CatalogRecoveryAction?
    @State private var sourcePendingRemoval: LibrarianModel.SourceFolder?
    @State private var showModelSetup = false
    @State private var resumeAnalysisAfterSetup = false
    @State private var showFolderDetails = false
    @FocusState private var searchFocused: Bool

    private var eligibleSources: [LibrarianModel.SourceFolder] {
        model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }
    }

    /// Why the primary Analyze/setup action is unavailable. Model setup is not
    /// a disabled state: if it is needed, the same button starts it.
    private var analyzeDisabledReason: String? {
        if !model.catalogReady { return "The encrypted catalog is not open — see the message below." }
        if model.sources.isEmpty { return "Choose a folder first — Private Librarian only looks at folders you hand it." }
        if let selectedSource, !selectedSourceIsEligible {
            if model.needsReauthorization(selectedSource) {
                return "\(scopeLabel) needs permission — use Allow or Re-authorize before analyzing it."
            }
            if model.isPaused(selectedSource) {
                return "\(scopeLabel) is paused — resume it before analyzing this folder."
            }
        }
        if eligibleSources.isEmpty {
            return "All folders are paused or need permission — resume or re-authorize one to analyze."
        }
        return nil
    }

    private var selectedSource: LibrarianModel.SourceFolder? {
        guard let selectedSourceID else { return nil }
        return model.sources.first { $0.id == selectedSourceID }
    }

    private var selectedSourceIsEligible: Bool {
        guard let selectedSource else { return true }
        return eligibleSources.contains { $0.id == selectedSource.id }
    }

    private var scopeLabel: String {
        guard let source = selectedSource else { return "All authorized folders" }
        let name = (source.path as NSString).lastPathComponent
        return name.isEmpty ? source.path : name
    }

    private var selectedProfileReady: Bool {
        model.isLocalModelProfileReady(model.localModelProfile)
    }

    private var profileDescription: String {
        switch model.localModelProfile {
        case .fast:
            return "Fast analysis uses deterministic rules and Apple Vision. No model download is required."
        case .balanced:
            return "Recommended. Adds local visual understanding and keeps uncertain files for review."
        case .quality:
            return "For harder libraries. Uses stronger local visual understanding and fallback checks, with more disk and memory use."
        }
    }

    private var primaryAnalyzeTitle: String {
        let scope = selectedSource == nil ? "all authorized folders" : scopeLabel
        return selectedProfileReady ? "Analyze \(scope)" : "Set Up & Analyze \(scope)"
    }

    private var primaryAnalyzeIcon: String {
        selectedProfileReady ? "sparkles" : "arrow.down.circle"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.catalogMigrationRequired || !model.catalogReady {
                        catalogCard
                    }

                    cleanupCard
                    analysisResultCard
                    foldersCard
                    resultCard
                    searchCard
                }
                .frame(maxWidth: 760)
                .padding(28)
                .frame(maxWidth: .infinity)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.selectedSection = .smart
                    openWindow(id: "advanced-library")
                } label: {
                    Label("Open Library", systemImage: "books.vertical")
                }
                .help("Open the full library workspace for groups, review, search, and missing files")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear {
            model.start()
            syncSelectionToLibraryScope()
        }
        .onChange(of: model.sources.map(\.id)) { _, _ in
            if let selectedSourceID,
               !model.sources.contains(where: { $0.id == selectedSourceID }) {
                self.selectedSourceID = nil
            }
        }
        .onChange(of: model.libraryScope) { _, _ in
            syncSelectionToLibraryScope()
        }
        .onChange(of: selectedSourceID) { _, _ in
            model.selectLibraryScope(selectedSource)
        }
        .sheet(isPresented: $showModelSetup) {
            ModelSetupView(
                profile: model.localModelProfile,
                onReady: {
                    let shouldResume = resumeAnalysisAfterSetup
                    resumeAnalysisAfterSetup = false
                    if shouldResume {
                        DispatchQueue.main.async { startCleanup() }
                    }
                },
                onUseFast: {
                    model.localModelProfile = .fast
                    let shouldResume = resumeAnalysisAfterSetup
                    resumeAnalysisAfterSetup = false
                    if shouldResume {
                        DispatchQueue.main.async { startCleanup() }
                    }
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
        .confirmationDialog(
            catalogRecoveryAction?.title ?? "Catalog recovery",
            isPresented: Binding(
                get: { catalogRecoveryAction != nil },
                set: { if !$0 { catalogRecoveryAction = nil } }),
            titleVisibility: .visible) {
                switch catalogRecoveryAction {
                case .startFresh:
                    Button("Start empty catalog", role: .destructive) {
                        model.startFreshCatalog()
                        catalogRecoveryAction = nil
                    }
                case .resetKey:
                    Button("Move old catalog aside and continue", role: .destructive) {
                        model.resetCatalogKeyAndStartFresh()
                        catalogRecoveryAction = nil
                    }
                case nil:
                    EmptyView()
                }
                Button("Cancel", role: .cancel) { catalogRecoveryAction = nil }
            } message: {
                switch catalogRecoveryAction {
                case .startFresh:
                    Text("The existing encrypted catalog will stay on disk, but this app will open a new empty catalog. Your source files are not touched.")
                case .resetKey:
                    Text("The unreadable catalog and its key will be moved aside, never deleted. A new encrypted catalog will be created. Use this only after migration cannot open the old library.")
                case nil:
                    Text("")
                }
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles.rectangle.stack.fill")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 2) {
                Text("Private Librarian")
                    .font(.headline)
                Text("Local cleanup · originals stay put until you apply a plan")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(selectedProfileReady ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.localModelProfile.shortDisplayName)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .help(selectedProfileReady ? "This quality level is ready" : "One-time local AI setup is needed for this quality level")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var cleanupCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(model.isIndexing ? "Analyzing \(scopeLabel)…" : model.isReconciling ? "Checking \(scopeLabel)…" : "Analyze your files safely")
                    .font(.title2.bold())
                Text("Private Librarian scans locally and suggests organization. Nothing moves until you review and confirm it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !model.sources.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Quality", selection: $model.localModelProfile) {
                        Text("Fast").tag(LocalModelProfile.fast)
                        Text("Balanced").tag(LocalModelProfile.balanced)
                        Text("Quality").tag(LocalModelProfile.quality)
                    }
                    .pickerStyle(.segmented)
                    Text(profileDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.localModelProfile != .fast, !selectedProfileReady {
                        HStack(alignment: .center, spacing: 8) {
                            Image(systemName: "arrow.down.circle")
                            VStack(alignment: .leading, spacing: 2) {
                                Text("One-time local setup needed")
                                    .font(.caption.weight(.medium))
                                Text("The main button will set it up and continue automatically.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Set Up") {
                                resumeAnalysisAfterSetup = false
                                showModelSetup = true
                            }
                            .font(.caption)
                        }
                        .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: 420)
            }

            if model.sources.isEmpty {
                Button {
                    model.addSourceFolder()
                } label: {
                    Label("Choose a Folder", systemImage: "folder.badge.plus")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Menu {
                    Button("All authorized folders") { selectedSourceID = nil }
                    if !model.sources.isEmpty {
                        Divider()
                    }
                    ForEach(model.sources) { source in
                        let name = (source.path as NSString).lastPathComponent
                        let status = model.needsReauthorization(source)
                            ? "Needs permission"
                            : model.isPaused(source) ? "Paused" : "Ready"
                        Button {
                            selectedSourceID = source.id
                        } label: {
                            HStack {
                                Text(name.isEmpty ? source.path : name)
                                Spacer()
                                Text(status)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } label: {
                    Label(scopeLabel, systemImage: "folder")
                        .frame(minWidth: 220)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Analysis scope: \(scopeLabel)")
                .help("Choose one authorized folder or analyze all authorized folders")

                if model.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: 360)

                    Button("Stop Analysis") {
                        model.cancelIndexing()
                    }
                    .keyboardShortcut(.cancelAction)
                } else if model.isReconciling {
                    ProgressView("Checking known paths…")
                        .controlSize(.small)
                        .frame(maxWidth: 360)
                } else {
                    Button {
                        handlePrimaryAnalyzeAction()
                    } label: {
                        Label(primaryAnalyzeTitle, systemImage: primaryAnalyzeIcon)
                            .font(.headline)
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.catalogReady || eligibleSources.isEmpty || !selectedSourceIsEligible)
                    .help(analyzeDisabledReason ?? "Read \(scopeLabel) and understand files without moving them")
                }
                if !model.isIndexing, !model.isReconciling, let reason = analyzeDisabledReason,
                   !model.sources.isEmpty || !model.catalogReady {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }

            if let status = model.latestStatusEvent {
                LibraryStatusLine(event: status)
                    .frame(maxWidth: 520)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var foldersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Authorized folders")
                    .font(.headline)
                Spacer()
                Button {
                    model.addSourceFolder()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if model.sources.isEmpty {
                Text("Only folders you add are included. Choose one to build your private library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.sources) { source in
                        sourceRow(source)
                        if source.id != model.sources.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func sourceRow(_ source: LibrarianModel.SourceFolder) -> some View {
        let name = (source.path as NSString).lastPathComponent
        let unavailable = model.needsReauthorization(source)
        let paused = model.isPaused(source)

        return HStack(spacing: 10) {
            Image(systemName: unavailable ? "exclamationmark.triangle.fill" : paused ? "pause.circle" : "folder.fill")
                .foregroundStyle(unavailable ? .orange : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(name.isEmpty ? source.path : name)
                    .lineLimit(1)
                Text(unavailable ? "Needs permission" : paused ? "Paused" : source.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if unavailable {
                Button("Allow \(name)") { model.reauthorizeSource(source) }
                    .help("Allow Private Librarian to read \(source.path)")
            }

            Menu {
                if !unavailable {
                    Button(paused ? "Resume" : "Pause") { model.togglePaused(source) }
                }
                Button("Re-authorize \(name)…") { model.reauthorizeSource(source) }
                Divider()
                Button("Remove…", role: .destructive) { sourcePendingRemoval = source }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(name)")
            .help("Folder actions for \(source.path)")
        }
        .padding(.vertical, 9)
    }

    private var resultCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Library at a glance")
                    .font(.headline)
                Spacer()
                if model.liveIndexRunning {
                    Label("Watching", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                compactMetric("Groups", value: model.smartGroups.count, icon: "square.grid.2x2")
                compactMetric("Review", value: model.dashboard.review, icon: "questionmark.circle")
                compactMetric("Duplicates", value: model.dashboard.duplicateGroups, icon: "square.on.square")
                compactMetric("Missing", value: model.dashboard.missing, icon: "exclamationmark.triangle")
            }

            HStack(spacing: 10) {
                Button("Review") {
                    model.selectedSection = .review
                    openWindow(id: "advanced-library")
                }
                .disabled(model.dashboard.review == 0)

                Button("Browse Groups") {
                    model.selectedSection = .smart
                    openWindow(id: "advanced-library")
                }

                Button("Duplicates") {
                    model.selectedSection = .duplicates
                    openWindow(id: "advanced-library")
                }
                .disabled(model.dashboard.duplicateGroups == 0)

                Button("Review missing…") {
                    model.selectedSection = .missing
                    openWindow(id: "advanced-library")
                }
                .disabled(!model.catalogReady || model.isIndexing || model.isReconciling)
                .help("Open Missing to check only catalog paths already known under your authorized folders")

                Spacer()
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The single place that answers "what just happened?" at library scope.
    /// Per-folder evidence is available on demand instead of becoming the
    /// primary workflow for every multi-folder analysis.
    @ViewBuilder
    private var analysisResultCard: some View {
        if let report = model.lastCleanupReport {
            let anyProblem = !report.ranCleanly || report.folders.contains { $0.unreadableDirectories > 0 }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Label(report.headline,
                          systemImage: anyProblem ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(report.finishedAt.formatted(date: .omitted, time: .shortened)) · \(String(format: "%.0f s", report.duration))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(report.summaryLine)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                DisclosureGroup(
                    "Show details for \(report.folders.count) folder" + (report.folders.count == 1 ? "" : "s"),
                    isExpanded: $showFolderDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.folders) { folder in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "folder.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                        Text(folder.displayName)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(1)
                                            .help(folder.rootPath)
                                        if folder.completion != "completed" {
                                            Text(folder.completion)
                                                .font(.caption2.weight(.medium))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(.orange.opacity(0.15), in: Capsule())
                                        }
                                        Spacer()
                                    }
                                    Text(folder.detailLine)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                        .textSelection(.enabled)
                                }
                                if folder.id != report.folders.last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                    .font(.caption)

                if model.smartGroups.isEmpty {
                    Text("No smart groups were created from this run. Review can still contain uncertain files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Groups ready · \(model.smartGroups.count)")
                            .font(.caption.weight(.medium))
                        FlowChips(items: model.smartGroups.prefix(8).map { group in
                            let growth = model.changedGroupIDs.contains(group.id) ? " · just updated" : ""
                            return "\(group.title) (\(group.fileIDs.count))\(growth)"
                        })
                        if model.smartGroups.count > 8 {
                            Text("+ \(model.smartGroups.count - 8) more groups in the Library")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Button {
                        model.selectedSection = .smart
                        openWindow(id: "advanced-library")
                    } label: {
                        Label("Review organization", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.borderedProminent)

                    Text("Nothing moved — applying a plan is always a separate, confirmed step.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                applyOutcomeFooter
            }
            .padding(18)
            .background(
                (anyProblem ? Color.orange.opacity(0.08) : Color.accentColor.opacity(0.08)),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    /// After the user has applied a plan in the Library window, the home
    /// screen shows the outcome and the Undo affordance — the move must not
    /// be invisible on the surface most people keep open.
    @ViewBuilder
    private var applyOutcomeFooter: some View {
        if model.canUndoApply || model.lastApplyMessage != nil || model.lastApplyFailureReport != nil {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 10) {
                    if model.canUndoApply {
                        Button("Undo Last Apply") { model.undoLastApply() }
                            .disabled(model.isApplyOperationInProgress || model.isReconciling)
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

    private func compactMetric(_ title: String, value: Int, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title3.bold())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Find anything")
                .font(.headline)

            HStack(spacing: 8) {
                TextField("Search files, OCR, transcripts, projects…", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .onSubmit { model.runSearch() }
                    .disabled(!model.catalogReady)

                Button {
                    model.runSearch()
                } label: {
                    if model.isSearching {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.catalogReady)
                .accessibilityLabel(model.isSearching ? "Searching library" : "Search library")
                .help("Search the private catalog")
            }

            if !model.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(model.searchResults.prefix(6)) { result in
                        SearchResultRow(result: result)
                    }
                    if model.searchResults.count > 6 {
                        Button("Open \(model.searchResults.count) results in Library") {
                            model.selectedSection = .overview
                            openWindow(id: "advanced-library")
                        }
                        .buttonStyle(.link)
                    }
                    Button("Clear search") { model.clearSearch() }
                        .buttonStyle(.link)
                }
            } else if model.searchFoundNothing, !model.isSearching {
                Text("No results for “\(model.query)”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var catalogCard: some View {
        if model.catalogMigrationRequired {
            VStack(alignment: .leading, spacing: 10) {
                Label("One-time catalog upgrade", systemImage: "key.fill")
                    .font(.headline)
                Text("Private Librarian found an older encrypted library. Migrate it once, or start a separate empty catalog. Your source files are untouched either way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Migrate existing library") { model.migrateCatalog() }
                        .buttonStyle(.borderedProminent)
                    Button("Start empty catalog…") { catalogRecoveryAction = .startFresh }
                        .help("Keep the existing encrypted library on disk and open a new empty catalog")
                }
            }
            .padding(16)
            .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if !model.catalogReady {
            VStack(alignment: .leading, spacing: 10) {
                Label("Library unavailable", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(model.catalogError ?? "Private Librarian could not open its encrypted catalog.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Try Again") { model.retryCatalogOpen() }
                    if model.catalogError != nil {
                        Button("Move blocked library aside…") { catalogRecoveryAction = .resetKey }
                            .help("Move the unreadable encrypted catalog aside without deleting it, then create a new one")
                    }
                }
            }
            .padding(16)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func handlePrimaryAnalyzeAction() {
        guard selectedProfileReady else {
            resumeAnalysisAfterSetup = true
            showModelSetup = true
            return
        }
        startCleanup()
    }

    private func startCleanup() {
        if let selectedSource {
            guard selectedSourceIsEligible else { return }
            model.selectLibraryScope(selectedSource)
            model.startIndexing(source: selectedSource)
        } else {
            model.selectLibraryScope(nil)
            model.startIndexing()
        }
    }

    private func syncSelectionToLibraryScope() {
        switch model.libraryScope {
        case .allAuthorized:
            selectedSourceID = nil
        case .source(let id):
            selectedSourceID = model.sources.contains(where: { $0.id == id }) ? id : nil
        }
    }
}

extension LocalModelProfile {
    var shortDisplayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .quality: return "Quality"
        }
    }
}

/// Simple wrapping row of capsule chips for compact summaries.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)],
                  alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(.background.opacity(0.7), in: Capsule())
                    .help(item)
            }
        }
    }
}
