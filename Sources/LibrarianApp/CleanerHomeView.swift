import SwiftUI
import LibrarianCore

/// The default product surface: one cleanup action, a small amount of state,
/// and progressive disclosure into the advanced catalog when the user asks.
/// The source filesystem remains read-only; this view only drives the existing
/// bounded indexing/catalog pipeline.
struct CleanerHomeView: View {
    @EnvironmentObject private var model: LibrarianModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSourceID: UUID?
    @FocusState private var searchFocused: Bool

    private var eligibleSources: [LibrarianModel.SourceFolder] {
        model.sources.filter { !model.isPaused($0) && !model.needsReauthorization($0) }
    }

    private var selectedSource: LibrarianModel.SourceFolder? {
        guard let selectedSourceID else { return nil }
        return eligibleSources.first { $0.id == selectedSourceID }
    }

    private var scopeLabel: String {
        guard let source = selectedSource else { return "All folders" }
        let name = (source.path as NSString).lastPathComponent
        return name.isEmpty ? source.path : name
    }

    private var imageJunkCount: Int {
        model.smartGroups.first(where: { $0.id == "category:Image/Junk" })?.fileIDs.count ?? 0
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
                    Label("Library", systemImage: "books.vertical")
                }
                .help("Open the advanced library")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
            }
        }
        .onAppear {
            model.start()
            if let selectedSourceID,
               !eligibleSources.contains(where: { $0.id == selectedSourceID }) {
                self.selectedSourceID = nil
            }
        }
        .onChange(of: model.sources.map(\.id)) { _, _ in
            if let selectedSourceID,
               !eligibleSources.contains(where: { $0.id == selectedSourceID }) {
                self.selectedSourceID = nil
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
                    .fill(model.isTier2Provisioned ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(model.localModelProfile.shortDisplayName)
                    .font(.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            .help(model.tier2Status)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var cleanupCard: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text(model.isIndexing ? "Cleaning up \(scopeLabel)…" : "Ready to clean up the mess?")
                    .font(.title2.bold())
                Text("Private Librarian scans locally, groups broadly, and keeps the source folders read-only.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if model.sources.isEmpty {
                Button {
                    model.addSourceFolder()
                } label: {
                    Label("Choose Folders", systemImage: "folder.badge.plus")
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Menu {
                    Button("All Authorized Folders") { selectedSourceID = nil }
                    if !eligibleSources.isEmpty {
                        Divider()
                    }
                    ForEach(eligibleSources) { source in
                        let name = (source.path as NSString).lastPathComponent
                        Button(name.isEmpty ? source.path : name) {
                            selectedSourceID = source.id
                        }
                    }
                } label: {
                    Label(scopeLabel, systemImage: "folder")
                        .frame(minWidth: 190)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                if model.isIndexing {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: 360)

                    Button("Stop Cleanup") {
                        model.cancelIndexing()
                    }
                    .keyboardShortcut(.cancelAction)
                } else {
                    Button {
                        startCleanup()
                    } label: {
                        Label("Clean Up", systemImage: "sparkles")
                            .font(.headline)
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!model.catalogReady || eligibleSources.isEmpty)
                }
            }

            if let status = model.statusLines.last {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var foldersCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folders")
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
                Text("Choose Downloads, Desktop, Projects, or any folders you want Librarian to understand.")
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
                Button("Allow") { model.reauthorizeSource(source) }
            }

            Menu {
                if !unavailable {
                    Button(paused ? "Resume" : "Pause") { model.togglePaused(source) }
                }
                Button("Re-authorize…") { model.reauthorizeSource(source) }
                Divider()
                Button("Remove", role: .destructive) { model.removeSource(source) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
                compactMetric("Image junk", value: imageJunkCount, icon: "photo.badge.exclamationmark")
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

                Spacer()
            }

            if let report = model.lastCleanupReport {
                cleanupSummary(report)
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// Answers "what folder did it just sort, and what came out of it?" —
    /// per-folder scan counts plus the groups this cleanup created or grew.
    private func cleanupSummary(_ report: LibrarianModel.CleanupReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Label("Last cleanup · \(report.finishedAt.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.seal")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            ForEach(report.folders) { folder in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(folder.displayName)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .help(folder.rootPath)
                    Text(folder.completion == "completed" ? "" : "· \(folder.completion)")
                        .font(.caption)
                        .foregroundStyle(folder.completion == "completed" ? .clear : .orange)
                    Spacer()
                    Text("\(folder.scanned) scanned · \(folder.processed) updated · \(folder.missingMarked) missing")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            if !model.changedGroupIDs.isEmpty {
                let changed = model.smartGroups.filter { model.changedGroupIDs.contains($0.id) }
                if !changed.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Organized now")
                            .font(.caption.weight(.medium))
                        FlowChips(items: changed.prefix(8).map { group in
                            "\(group.title) (\(group.fileIDs.count))"
                        })
                        if changed.count > 8 {
                            Text("+ \(changed.count - 8) more groups in the Library")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
            }

            if !model.searchResults.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(model.searchResults.prefix(6).enumerated()), id: \.offset) { _, result in
                        Text(result)
                            .font(.caption)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if model.searchResults.count > 6 {
                        Button("Open all results") {
                            model.selectedSection = .overview
                            openWindow(id: "advanced-library")
                        }
                        .buttonStyle(.link)
                    }
                }
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
                Text("Your existing encrypted library needs one Keychain migration. You can migrate it or start a fresh catalog; originals are untouched either way.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Migrate Existing Catalog") { model.migrateCatalog() }
                        .buttonStyle(.borderedProminent)
                    Button("Start Fresh") { model.startFreshCatalog() }
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
                Button("Try Again") { model.retryCatalogOpen() }
            }
            .padding(16)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func startCleanup() {
        if let selectedSource {
            model.startIndexing(source: selectedSource)
        } else {
            model.startIndexing()
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
