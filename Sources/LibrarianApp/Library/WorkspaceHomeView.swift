import SwiftUI
import LibrarianCore
import LibrarianAppSupport

/// Consumer-first organizer workspace.
///
/// The old home screen was a vertical stack of independent cards. This keeps
/// the product's real mental model visible at once: authorized sources on the
/// left, recommendations/search in the center, and the selected recommendation
/// with its exact next action on the right. Finder mutations remain previewed,
/// explicit, journaled, and undoable.
struct WorkspaceHomeView: View {
    private enum PendingAnalysis: Equatable {
        case all
        case source(UUID)
    }

    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.openWindow) private var openWindow

    @State private var selectedSourceID: UUID?
    @State private var selectedGroupID: String?
    @State private var sourcePendingRemoval: LibrarianModel.SourceFolder?
    @State private var showModelSetup = false
    @State private var pendingAnalysis: PendingAnalysis?
    @FocusState private var searchFocused: Bool

    private var selectedSource: LibrarianModel.SourceFolder? {
        guard let selectedSourceID else { return nil }
        return model.sources.first { $0.id == selectedSourceID }
    }

    private var eligibleSources: [LibrarianModel.SourceFolder] {
        model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }
    }

    private var selectedGroup: SmartOrganizationGroup? {
        guard let selectedGroupID else { return nil }
        return model.smartGroups.first { $0.id == selectedGroupID }
    }

    private var actionableGroups: [SmartOrganizationGroup] {
        model.smartGroups.filter(\.canApplyToFinder)
    }

    private var currentScopeName: String {
        guard let selectedSource else { return "All folders" }
        let name = (selectedSource.path as NSString).lastPathComponent
        return name.isEmpty ? selectedSource.path : name
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 205, ideal: 230, max: 270)
        } detail: {
            VStack(spacing: 0) {
                commandBar
                Divider()

                if !model.catalogReady {
                    blockedState
                } else if model.sources.isEmpty {
                    onboardingState
                } else if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || !model.searchResults.isEmpty {
                    searchWorkspace
                } else {
                    organizerWorkspace
                }

                Divider()
                activityBar
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    searchFocused = true
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("k", modifiers: [.command])
                .help("Search the library (⌘K)")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear {
            model.start()
            syncSelectedSource()
            chooseDefaultGroup()
        }
        .onChange(of: model.libraryScope) { _, _ in syncSelectedSource() }
        .onChange(of: selectedSourceID) { _, _ in
            model.selectLibraryScope(selectedSource)
        }
        .onChange(of: model.smartGroups.map(\.id)) { _, _ in
            chooseDefaultGroup()
        }
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
        .sheet(item: $model.pendingApplyPlan) { plan in
            WorkspaceApplyPreviewSheet(plan: plan)
                .environmentObject(model)
        }
        .confirmationDialog(
            "Remove “\(sourcePendingRemoval.map { ($0.path as NSString).lastPathComponent } ?? "")”?",
            isPresented: Binding(
                get: { sourcePendingRemoval != nil },
                set: { if !$0 { sourcePendingRemoval = nil } }),
            titleVisibility: .visible) {
                Button("Remove from Library", role: .destructive) {
                    if let source = sourcePendingRemoval { model.removeSource(source) }
                    sourcePendingRemoval = nil
                }
                Button("Cancel", role: .cancel) { sourcePendingRemoval = nil }
            } message: {
                Text("The original folder is not changed. It simply disappears from this library until you add it again.")
            }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section {
                Button {
                    model.clearSearch()
                    selectedGroupID = actionableGroups.first?.id ?? model.smartGroups.first?.id
                } label: {
                    sidebarRow("Organize", icon: "sparkles.rectangle.stack", count: actionableGroups.count)
                }
                .buttonStyle(.plain)

                Button { openLibrary(.review) } label: {
                    sidebarRow("Needs Review", icon: "questionmark.folder", count: model.dashboard.review)
                }
                .buttonStyle(.plain)

                Button { openLibrary(.duplicates) } label: {
                    sidebarRow("Duplicates", icon: "square.on.square", count: model.dashboard.duplicateGroups)
                }
                .buttonStyle(.plain)

                Button { openLibrary(.missing) } label: {
                    sidebarRow("Missing", icon: "exclamationmark.triangle", count: model.dashboard.missing)
                }
                .buttonStyle(.plain)
            } header: {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Private Librarian", systemImage: "books.vertical.fill")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Local · private · reversible")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                .padding(.bottom, 4)
            }

            Section("Sources") {
                Button {
                    selectedSourceID = nil
                } label: {
                    sourceScopeRow(
                        title: "All folders",
                        subtitle: "\(model.sources.count) authorized",
                        icon: "square.grid.2x2",
                        selected: selectedSourceID == nil)
                }
                .buttonStyle(.plain)

                ForEach(model.sources) { source in
                    sourceSidebarRow(source)
                }

                Button {
                    model.addSourceFolder()
                } label: {
                    Label("Add Folder…", systemImage: "plus")
                }
            }

            Section("Analysis") {
                Picker("Quality", selection: $model.localModelProfile) {
                    Text("Fast").tag(LocalModelProfile.fast)
                    Text("Balanced").tag(LocalModelProfile.balanced)
                    Text("Quality").tag(LocalModelProfile.quality)
                }
                .pickerStyle(.menu)

                if model.isIndexing {
                    Button(role: .destructive) {
                        model.cancelIndexing()
                    } label: {
                        Label("Stop Analysis", systemImage: "stop.circle")
                    }
                } else {
                    Button {
                        requestAnalysis(selectedSource)
                    } label: {
                        Label(
                            model.isLocalModelProfileReady(model.localModelProfile)
                                ? "Analyze \(currentScopeName)" : "Set Up & Analyze",
                            systemImage: model.isLocalModelProfileReady(model.localModelProfile)
                                ? "sparkles" : "arrow.down.circle")
                    }
                    .disabled(eligibleSources.isEmpty || (selectedSource != nil && !selectedSourceIsEligible))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
            Text(title)
            Spacer(minLength: 6)
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
        }
    }

    private func sourceSidebarRow(_ source: LibrarianModel.SourceFolder) -> some View {
        let name = (source.path as NSString).lastPathComponent
        let unavailable = model.needsReauthorization(source)
        let paused = model.isPaused(source)

        return HStack(spacing: 6) {
            Button {
                selectedSourceID = source.id
            } label: {
                sourceScopeRow(
                    title: name.isEmpty ? source.path : name,
                    subtitle: unavailable ? "Needs permission" : paused ? "Paused" : "Ready",
                    icon: unavailable ? "exclamationmark.triangle.fill" : paused ? "pause.circle" : "folder.fill",
                    selected: selectedSourceID == source.id,
                    warning: unavailable || paused)
            }
            .buttonStyle(.plain)

            Menu {
                if unavailable {
                    Button("Allow Access…") { model.reauthorizeSource(source) }
                } else {
                    Button(paused ? "Resume Analysis" : "Pause Analysis") { model.togglePaused(source) }
                    Button("Re-authorize…") { model.reauthorizeSource(source) }
                }
                Divider()
                Button("Remove from Library…", role: .destructive) { sourcePendingRemoval = source }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 18, height: 18)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func sourceScopeRow(
        title: String,
        subtitle: String,
        icon: String,
        selected: Bool,
        warning: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(warning ? Color.orange : selected ? Color.accentColor : Color.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(warning ? .orange : .secondary)
            }
            Spacer(minLength: 2)
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Command/search surface

    private var commandBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search names, document text, screenshots, projects…", text: $model.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { model.runSearch() }
                    .disabled(!model.catalogReady)
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.query.isEmpty {
                    Button {
                        model.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
                Text("⌘K")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Menu {
                Button("Analyze all folders") { requestAnalysis(nil) }
                ForEach(eligibleSources) { source in
                    let name = (source.path as NSString).lastPathComponent
                    Button("Analyze \(name.isEmpty ? source.path : name)") {
                        requestAnalysis(source)
                    }
                }
            } label: {
                Label(model.isIndexing ? "Analyzing…" : "Analyze", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isIndexing || model.isReconciling || eligibleSources.isEmpty)

            Button {
                model.refreshDashboard()
                model.refreshModelStatus()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - Main organizer

    private var organizerWorkspace: some View {
        VStack(spacing: 0) {
            workspaceSummary
            Divider()

            if model.smartGroups.isEmpty {
                ContentUnavailableView {
                    Label("No recommendations yet", systemImage: "sparkles.rectangle.stack")
                } description: {
                    Text("Analyze a folder. Private Librarian will suggest a small set of useful groups without moving anything.")
                } actions: {
                    Button("Analyze \(currentScopeName)") { requestAnalysis(selectedSource) }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    recommendationList
                        .frame(minWidth: 380, idealWidth: 520)
                    recommendationInspector
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 440)
                }
            }
        }
    }

    private var workspaceSummary: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ready to organize")
                    .font(.title2.bold())
                Text("\(actionableGroups.count) move-ready group\(actionableGroups.count == 1 ? "" : "s") · \(model.dashboard.review) need review · originals stay put")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            if let report = model.lastCleanupReport {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(report.headline)
                        .font(.caption.weight(.semibold))
                    Text(report.summaryLine)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if model.dashboard.review > 0 {
                Button("Review \(model.dashboard.review)") { openLibrary(.review) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var recommendationList: some View {
        ScrollView {
            LazyVStack(spacing: 7) {
                ForEach(model.smartGroups) { group in
                    recommendationRow(group)
                }
            }
            .padding(12)
        }
        .background(.background)
    }

    private func recommendationRow(_ group: SmartOrganizationGroup) -> some View {
        let selected = selectedGroupID == group.id
        return Button {
            selectedGroupID = group.id
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon(for: group))
                    .font(.title3)
                    .foregroundStyle(group.canApplyToFinder ? Color.accentColor : Color.secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if !group.canApplyToFinder {
                            Text("relationship")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(group.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Text("\(group.fileIDs.count)")
                    .font(.callout.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(
                selected ? Color.accentColor.opacity(0.13) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.fileIDs.count) items")
    }

    @ViewBuilder
    private var recommendationInspector: some View {
        if let group = selectedGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: icon(for: group))
                            .font(.title2)
                            .foregroundStyle(group.canApplyToFinder ? Color.accentColor : Color.secondary)
                            .frame(width: 36, height: 36)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.title)
                                .font(.title3.bold())
                            Text("\(group.fileIDs.count) item\(group.fileIDs.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if group.canApplyToFinder {
                        beforeAfterSummary(group)
                    } else {
                        Label("This is a relationship view, not a Finder destination.", systemImage: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Files in this recommendation")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        ForEach(Array(group.fileIDs.prefix(8)), id: \.self) { id in
                            let path = model.filePath(for: id)
                            HStack(spacing: 8) {
                                Image(systemName: fileIcon(path))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((path as NSString).lastPathComponent)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                    Text((path as NSString).deletingLastPathComponent)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }

                        if group.fileIDs.count > 8 {
                            Text("+ \(group.fileIDs.count - 8) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider()

                    if group.canApplyToFinder {
                        Button {
                            model.prepareApply(group: group)
                        } label: {
                            Label("Review Moves", systemImage: "checklist")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(model.isPreparingPlan || model.isApplyOperationInProgress || model.isReconciling)
                        .help("Preview every Finder move. Nothing changes until you confirm.")
                    }

                    Button("Open full group in Library") {
                        openLibrary(.smart)
                    }
                    .buttonStyle(.link)
                }
                .padding(18)
            }
            .background(.quaternary.opacity(0.25))
        } else {
            ContentUnavailableView(
                "Select a recommendation",
                systemImage: "sidebar.right",
                description: Text("Its files, reasoning, and safe next action will appear here."))
        }
    }

    private func beforeAfterSummary(_ group: SmartOrganizationGroup) -> some View {
        let parentNames = Set(group.fileIDs.prefix(32).compactMap { id -> String? in
            let path = model.filePath(for: id)
            guard !path.isEmpty else { return nil }
            let parent = (path as NSString).deletingLastPathComponent
            let name = (parent as NSString).lastPathComponent
            return name.isEmpty ? parent : name
        })
        let sourceLabel = parentNames.count <= 1
            ? (parentNames.first ?? currentScopeName)
            : "\(parentNames.count) locations"

        return VStack(alignment: .leading, spacing: 10) {
            Text("Proposed organization")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 9) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Now")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(sourceLabel, systemImage: "tray.full")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Suggested")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Label(group.title, systemImage: "folder.fill")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                }
            }
            .padding(11)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            Text(group.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Search

    private var searchWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search")
                        .font(.title2.bold())
                    Text(model.query.isEmpty ? "Recent results" : "Results for “\(model.query)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Search") { model.runSearch() }
                        .disabled(model.isSearching)
                }
            }
            .padding(18)
            Divider()

            if model.searchResults.isEmpty {
                if model.isSearching {
                    ProgressView("Searching your private library…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.searchFoundNothing {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView(
                        "Type and press Return",
                        systemImage: "magnifyingglass",
                        description: Text("Search filenames, extracted document text, OCR, transcripts, and local semantic indexes."))
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.searchResults.prefix(80).enumerated()), id: \.element.id) { index, result in
                            SearchResultRow(result: result)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                            if index < min(80, model.searchResults.count) - 1 { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty/error states

    private var onboardingState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 7) {
                Text("Give Librarian one messy folder")
                    .font(.largeTitle.bold())
                Text("Start with Downloads or Desktop. Analysis is local, read-only, and nothing moves until you review a plan.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 580)
            }
            Button {
                model.addSourceFolder()
            } label: {
                Label("Choose a Folder", systemImage: "folder.badge.plus")
                    .frame(minWidth: 190)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            HStack(spacing: 18) {
                onboardingPromise("On-device analysis", "lock.shield")
                onboardingPromise("Preview every move", "checklist")
                onboardingPromise("Undo Finder changes", "arrow.uturn.backward")
            }
            Spacer()
        }
        .padding(32)
    }

    private func onboardingPromise(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var blockedState: some View {
        ContentUnavailableView {
            Label("Library unavailable", systemImage: "lock.trianglebadge.exclamationmark")
        } description: {
            Text(model.catalogError ?? "The encrypted catalog could not be opened. Your source files have not been changed.")
        } actions: {
            SettingsLink { Text("Open Settings") }
        }
    }

    // MARK: - Activity / safety

    private var activityBar: some View {
        HStack(spacing: 10) {
            if model.liveIndexRunning {
                Label("Watching", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.secondary)
            } else {
                Label("Local", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }

            if let event = model.latestStatusEvent {
                Text(event.message)
                    .foregroundStyle(event.isWarning ? .orange : .secondary)
                    .lineLimit(1)
            } else {
                Text("Nothing moves until you review and apply a plan")
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if model.isApplyOperationInProgress {
                ProgressView().controlSize(.small)
                Text("Moving…").foregroundStyle(.secondary)
            } else if model.canUndoApply {
                Button {
                    model.undoLastApply()
                } label: {
                    Label("Undo \(model.undoBatchFileCount)", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Undo the latest Finder apply batch")
            }

            if let message = model.lastApplyMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Actions

    private var selectedSourceIsEligible: Bool {
        guard let selectedSource else { return true }
        return eligibleSources.contains { $0.id == selectedSource.id }
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
        guard let pendingAnalysis else { return }
        self.pendingAnalysis = nil
        runAnalysis(pendingAnalysis)
    }

    private func runAnalysis(_ request: PendingAnalysis) {
        switch request {
        case .all:
            guard !eligibleSources.isEmpty else { return }
            selectedSourceID = nil
            model.selectLibraryScope(nil)
            model.startIndexing()
        case .source(let id):
            guard let source = eligibleSources.first(where: { $0.id == id }) else { return }
            selectedSourceID = source.id
            model.selectLibraryScope(source)
            model.startIndexing(source: source)
        }
    }

    private func openLibrary(_ section: LibrarySection) {
        model.selectedSection = section
        openWindow(id: "advanced-library")
    }

    private func syncSelectedSource() {
        selectedSourceID = model.libraryScopeSource?.id
    }

    private func chooseDefaultGroup() {
        if let selectedGroupID, model.smartGroups.contains(where: { $0.id == selectedGroupID }) {
            return
        }
        self.selectedGroupID = actionableGroups.first?.id ?? model.smartGroups.first?.id
    }

    private func icon(for group: SmartOrganizationGroup) -> String {
        switch group.kind {
        case .category: return "folder.badge.sparkles"
        case .nearDuplicate: return "square.on.square"
        case .semantic: return "point.3.connected.trianglepath.dotted"
        }
    }

    private func fileIcon(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "heic", "webp", "gif": return "photo"
        case "zip", "7z", "rar", "tar", "gz": return "archivebox"
        case "swift", "java", "py", "js", "ts", "c", "cpp", "h": return "chevron.left.forwardslash.chevron.right"
        default: return "doc"
        }
    }
}

/// Sortio-style before/after safety, kept within the product's stricter
/// journaled-apply contract. The user sees the destination and exact moves,
/// may exclude individual files, and must confirm before Finder is mutated.
private struct WorkspaceApplyPreviewSheet: View {
    @EnvironmentObject private var model: LibrarianModel
    let plan: OrganizationApplier.Plan

    @State private var selectedRootPath = ""
    @State private var excludedFileIDs: Set<String> = []
    @State private var showFinalConfirmation = false

    private var selectedCount: Int { max(0, plan.items.count - excludedFileIDs.count) }

    private var rootSelection: Binding<String> {
        Binding(
            get: { selectedRootPath.isEmpty ? plan.destinationRootPath : selectedRootPath },
            set: { newRoot in
                selectedRootPath = newRoot
                model.replanApply(to: newRoot)
            })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.title2)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review Moves")
                        .font(.title2.bold())
                    Text(plan.groupTitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { model.cancelApply() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Divider()

            HSplitView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Destination")
                        .font(.headline)

                    if plan.candidateRootPaths.count > 1 {
                        Picker("Authorized folder", selection: rootSelection) {
                            ForEach(plan.candidateRootPaths, id: \.self) { root in
                                Text((root as NSString).lastPathComponent.isEmpty ? root : (root as NSString).lastPathComponent)
                                    .tag(root)
                            }
                        }
                        .disabled(model.isPreparingPlan)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text((plan.destinationFolderPath as NSString).lastPathComponent)
                            .font(.title3.bold())
                        Text(plan.destinationFolderPath)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10))

                    LabeledContent("Will move") { Text("\(selectedCount)").monospacedDigit() }
                    if plan.alreadyInPlace > 0 {
                        LabeledContent("Already there") { Text("\(plan.alreadyInPlace)").monospacedDigit() }
                    }
                    if plan.skippedOtherRoots > 0 {
                        LabeledContent("Other roots untouched") { Text("\(plan.skippedOtherRoots)").monospacedDigit() }
                    }
                    if !plan.missingPaths.isEmpty {
                        LabeledContent("Unavailable") { Text("\(plan.missingPaths.count)").monospacedDigit() }
                    }

                    Spacer()

                    Label("Preview only — no file has moved", systemImage: "lock.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(18)
                .frame(minWidth: 250, idealWidth: 290)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Exact moves")
                            .font(.headline)
                        Spacer()
                        Text("\(selectedCount) selected")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    if model.isPreparingPlan {
                        ProgressView("Updating preview…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(plan.items, id: \.fileID) { item in
                                    Toggle(isOn: Binding(
                                        get: { !excludedFileIDs.contains(item.fileID) },
                                        set: { include in
                                            if include { excludedFileIDs.remove(item.fileID) }
                                            else { excludedFileIDs.insert(item.fileID) }
                                        })) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text((item.fromPath as NSString).lastPathComponent)
                                                .font(.callout.weight(.medium))
                                            HStack(spacing: 5) {
                                                Text((item.fromPath as NSString).deletingLastPathComponent)
                                                Image(systemName: "arrow.right")
                                                Text((item.toPath as NSString).deletingLastPathComponent)
                                            }
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                    .padding(.vertical, 8)
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(minWidth: 430, idealWidth: 560)
            }

            Divider()

            HStack(spacing: 10) {
                Text("Moves are journaled and can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !excludedFileIDs.isEmpty {
                    Button("Include All") { excludedFileIDs.removeAll() }
                }
                Button("Apply \(selectedCount) Move\(selectedCount == 1 ? "" : "s")") {
                    showFinalConfirmation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedCount == 0 || model.isPreparingPlan)
            }
            .padding(16)
        }
        .frame(width: 900, height: 620)
        .confirmationDialog(
            "Move \(selectedCount) file\(selectedCount == 1 ? "" : "s") into “\((plan.destinationFolderPath as NSString).lastPathComponent)”?",
            isPresented: $showFinalConfirmation,
            titleVisibility: .visible) {
                Button("Apply Moves") {
                    model.confirmApply(excluding: excludedFileIDs)
                }
                Button("Keep Reviewing", role: .cancel) {}
            } message: {
                Text("This changes Finder. The operation is journaled so the latest successful batch can be undone.")
            }
    }
}
