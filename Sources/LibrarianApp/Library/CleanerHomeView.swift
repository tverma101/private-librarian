import SwiftUI
import LibrarianCore

/// Shared recovery choices used by both the main and advanced Library surfaces.
/// Recovery changes only the encrypted catalog; source files are never touched.
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

/// Stable primary-scene entry point around the redesigned workspace. Catalog
/// opening/recovery belongs here so a broken or older catalog never leaves the
/// main window in a dead-end state, and apply failures remain visible even
/// after the preview sheet closes.
struct CleanerHomeView: View {
    @EnvironmentObject private var model: LibrarianModel
    @State private var catalogRecoveryAction: CatalogRecoveryAction?
    @State private var showApplyFailureDetails = false

    var body: some View {
        Group {
            if model.catalogReady {
                WorkspaceHomeView()
            } else {
                catalogGate
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .onAppear { model.start() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.catalogReady, let report = model.lastApplyFailureReport {
                failureBanner(report)
            }
        }
        .sheet(isPresented: $showApplyFailureDetails) {
            if let report = model.lastApplyFailureReport {
                ApplyFailureDetailsSheet(report: report)
            }
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
                    Text("The existing encrypted catalog stays on disk, while Private Librarian opens a separate empty catalog. Source files are not touched.")
                case .resetKey:
                    Text("The unreadable catalog and key are moved aside, never deleted. A new encrypted catalog is created; source files are not touched.")
                case nil:
                    Text("")
                }
            }
    }

    @ViewBuilder
    private var catalogGate: some View {
        if model.catalogMigrationRequired {
            VStack(spacing: 18) {
                Image(systemName: "key.fill")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.orange)

                VStack(spacing: 7) {
                    Text("One-time library upgrade")
                        .font(.title.bold())
                    Text("An older encrypted Private Librarian catalog was found. Upgrade it once, or start a separate empty catalog. Your source files are untouched either way.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }

                HStack(spacing: 10) {
                    Button(model.catalogMigrationAttempted ? "Migration attempted" : "Upgrade Existing Library") {
                        model.migrateCatalog()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.catalogMigrationAttempted)

                    Button("Start Empty Library…") {
                        catalogRecoveryAction = .startFresh
                    }
                    .controlSize(.large)
                }

                if model.catalogMigrationAttempted {
                    Text("If the upgrade did not complete, retry the app or choose an empty catalog. The existing encrypted catalog remains on disk.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                }
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.catalogError, !error.isEmpty {
            VStack(spacing: 18) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.red)

                VStack(spacing: 7) {
                    Text("Private library could not open")
                        .font(.title.bold())
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 640)
                }

                HStack(spacing: 10) {
                    Button("Try Again") { model.retryCatalogOpen() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Move Blocked Library Aside…") {
                        catalogRecoveryAction = .resetKey
                    }
                    .controlSize(.large)
                }

                Text("Recovery only changes Private Librarian's encrypted catalog. Files in your authorized folders are never deleted or rewritten by this action.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 580)
            }
            .padding(36)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                Text("Opening your private library…")
                    .font(.headline)
                Text("Encrypted catalog · local only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func failureBanner(_ report: LibrarianModel.ApplyFailureReport) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(report.title)
                    .font(.caption.weight(.semibold))
                Text("\(report.failures.count) file\(report.failures.count == 1 ? "" : "s") could not be changed. Successful moves remain journaled and undoable.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Show Failed Files") {
                showApplyFailureDetails = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct ApplyFailureDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let report: LibrarianModel.ApplyFailureReport

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.title)
                        .font(.title2.bold())
                    Text("\(report.failures.count) failed file\(report.failures.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 4) {
                            Text((failure.path as NSString).lastPathComponent)
                                .font(.subheadline.weight(.semibold))
                            Text(failure.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Text(failure.reason)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        Divider()
                    }
                }
            }
        }
        .frame(width: 720, height: 480)
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

/// Compact wrapping chips are still used by secondary library surfaces.
struct FlowChips: View {
    let items: [String]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
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
