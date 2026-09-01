import Foundation
import LibrarianCore

/// Access seam for materializing an apply plan. In production this is a
/// `SecurityScopedBookmarkLease`; tests inject a plain-path lease. The lease
/// grants exactly the scope the user authorized — there is no raw-path
/// fallback and no access outside the authorized roots.
public protocol OrganizationLease: Sendable {
    var url: URL { get }
    /// Map a catalog-space path under the authorized root to the lease's
    /// resolved location, or nil when the path is outside the scope.
    func targetURL(for requestedPath: String, originalRootPath: String) -> URL?
}

extension SecurityScopedBookmarkLease: OrganizationLease {}

/// One user-approved materialization of a virtual smart group: the group's
/// member files are moved into a named folder inside the source root where
/// most of the members already live. Every successful move is journaled in
/// the encrypted catalog so the batch can be undone, and the catalog row's
/// recorded path is updated so virtual groups stay coherent afterwards.
///
/// The appler only ever moves regular files that the catalog already knows
/// about, only within a root the user explicitly authorized, and never
/// follows symlinks out of that scope.
public enum OrganizationApplier {

    public struct Plan: Sendable, Equatable, Identifiable {
        public struct Item: Sendable, Equatable {
            public let fileID: String
            public let fromPath: String
        }

        public let id: String
        public let groupID: String
        public let groupTitle: String
        public let folderName: String
        public let destinationRootPath: String
        public let items: [Item]
        public let missingPaths: [String]
        public let skippedOtherRoots: Int

        /// Catalog-space destination folder path (what the user will see).
        public var destinationFolderPath: String {
            destinationRootPath + "/" + folderName
        }
    }

    public struct Outcome: Sendable, Equatable {
        public struct Failure: Sendable, Equatable {
            public let path: String
            public let reason: String
        }

        public let batchID: String
        public let moved: Int
        public let destinationFolderPath: String
        public let failures: [Failure]
        public let skippedOtherRoots: Int
        public let missingPaths: [String]
        public var succeeded: Bool { failures.isEmpty }
    }

    public struct UndoOutcome: Sendable, Equatable {
        public let batchID: String
        public let restored: Int
        public let failures: [Outcome.Failure]
        public var succeeded: Bool { failures.isEmpty }
    }

    public enum ApplyError: Error, LocalizedError, Equatable {
        case noMembers
        case noAuthorizedRoot

        public var errorDescription: String? {
            switch self {
            case .noMembers: return "This group has no movable files."
            case .noAuthorizedRoot: return "The folder holding these files is no longer authorized. Re-authorize it and try again."
            }
        }
    }

    // MARK: - Planning

    /// Build a preview plan. `pathFor` resolves catalog file IDs to recorded
    /// source paths; `sourceRoots` are the currently authorized roots.
    public static func plan(
        group: SmartOrganizationGroup,
        pathFor: (String) -> String,
        sourceRoots: [String]
    ) throws -> Plan {
        let members = group.fileIDs.map { (fileID: $0, path: pathFor($0)) }
            .filter { !$0.path.isEmpty }
        guard !members.isEmpty else { throw ApplyError.noMembers }

        // Longest matching authorized root wins, so nested roots behave.
        func rootFor(_ path: String) -> String? {
            sourceRoots
                .filter { SourceBroker.isPath(path, under: $0) || path == $0 }
                .max(by: { $0.count < $1.count })
        }

        var byRoot: [String: [(fileID: String, path: String)]] = [:]
        var missing: [String] = []
        for member in members {
            guard let root = rootFor(member.path) else {
                missing.append(member.path)
                continue
            }
            byRoot[root, default: []].append(member)
        }
        guard let destinationRoot = byRoot.max(by: { $0.value.count < $1.value.count })?.key else {
            throw ApplyError.noAuthorizedRoot
        }

        let folderName = sanitizedFolderName(from: group.title)
        let destinationMembers = byRoot[destinationRoot] ?? []
        var missingPaths: [String] = []
        var items: [Plan.Item] = []
        for member in destinationMembers {
            if FileManager.default.fileExists(atPath: member.path) {
                items.append(Plan.Item(fileID: member.fileID, fromPath: member.path))
            } else {
                missingPaths.append(member.path)
            }
        }
        let skippedOtherRoots = members.count - destinationMembers.count
        return Plan(
            id: UUID().uuidString,
            groupID: group.id,
            groupTitle: group.title,
            folderName: folderName,
            destinationRootPath: destinationRoot,
            items: items,
            missingPaths: missingPaths.sorted(),
            skippedOtherRoots: skippedOtherRoots)
    }

    /// Folder names stay single-level and filesystem-safe.
    static func sanitizedFolderName(from title: String) -> String {
        var name = title
        for separator in ["/", ":", "\0"] where name.contains(separator) {
            name = name.replacingOccurrences(of: separator, with: " ")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Organized files" }
        return String(name.prefix(80))
    }

    // MARK: - Applying

    /// Execute a plan. `leaseForRoot` must return an active lease for the
    /// destination root; moves happen inside that security scope only.
    public static func apply(
        plan: Plan,
        leaseForRoot: (String) throws -> any OrganizationLease,
        catalog: Catalog
    ) throws -> Outcome {
        guard !plan.items.isEmpty else { throw ApplyError.noMembers }
        let batchID = plan.id
        let lease = try leaseForRoot(plan.destinationRootPath)
        let broker = SourceBroker()

        let destinationURL = lease.url.appendingPathComponent(plan.folderName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destinationURL,
                                                    withIntermediateDirectories: true)
        } catch {
            throw ApplyError.noAuthorizedRoot
        }

        var moved: Int = 0
        var journal: [Catalog.ApplyJournalEntry] = []
        var failures: [Outcome.Failure] = []

        for item in plan.items {
            guard let sourceURL = lease.targetURL(for: item.fromPath,
                                                  originalRootPath: plan.destinationRootPath),
                  broker.pathIsInsideScope(item.fromPath, under: plan.destinationRootPath) else {
                failures.append(.init(path: item.fromPath, reason: "outside the authorized folder"))
                continue
            }
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                failures.append(.init(path: item.fromPath, reason: "file is gone"))
                continue
            }
            let fileName = sourceURL.lastPathComponent
            let targetURL = conflictFreeDestination(for: fileName, in: destinationURL)
            do {
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            } catch {
                failures.append(.init(path: item.fromPath, reason: error.localizedDescription))
                continue
            }
            let toPath = plan.destinationRootPath + "/" + plan.folderName + "/" + targetURL.lastPathComponent
            journal.append(.init(fileID: item.fileID, fromPath: item.fromPath, toPath: toPath))
            moved += 1
        }

        // Journal first (so undo is always possible), then reconcile the
        // catalog row paths. Path updates are guarded by the original path.
        if !journal.isEmpty {
            try catalog.recordApplyBatch(batchID: batchID,
                                         appliedAt: Date().timeIntervalSince1970,
                                         entries: journal)
            for entry in journal {
                try? catalog.updateAppliedPath(fileID: entry.fileID,
                                               fromPath: entry.fromPath,
                                               toPath: entry.toPath)
            }
        }

        return Outcome(batchID: batchID,
                       moved: moved,
                       destinationFolderPath: plan.destinationFolderPath,
                       failures: failures,
                       skippedOtherRoots: plan.skippedOtherRoots,
                       missingPaths: plan.missingPaths)
    }

    /// Move the most recent batch back to where the files came from. Batches
    /// whose entries were all restored are removed from the journal; partial
    /// undos keep the remaining rows so a later retry can finish the job.
    public static func undoLatest(
        catalog: Catalog,
        sourceRoots: [String],
        leaseForRoot: (String) throws -> any OrganizationLease
    ) -> UndoOutcome? {
        guard let batchID = (try? catalog.latestApplyBatchID()).flatMap({ $0 }),
              let entries = try? catalog.applyBatchEntries(batchID: batchID), !entries.isEmpty else {
            return nil
        }
        var restored = 0
        var failures: [Outcome.Failure] = []
        var undone: [Catalog.ApplyJournalEntry] = []

        func rootFor(_ path: String) -> String? {
            sourceRoots
                .filter { SourceBroker.isPath(path, under: $0) }
                .max(by: { $0.count < $1.count })
        }

        for entry in entries.reversed() {
            guard let root = rootFor(entry.toPath) ?? rootFor(entry.fromPath) else {
                failures.append(.init(path: entry.toPath, reason: "its folder is no longer authorized"))
                continue
            }
            guard let lease = try? leaseForRoot(root),
                  let fromURL = lease.targetURL(for: entry.toPath, originalRootPath: root),
                  let backURL = lease.targetURL(for: entry.fromPath, originalRootPath: root) else {
                failures.append(.init(path: entry.toPath, reason: "folder access could not be restored"))
                continue
            }
            guard FileManager.default.fileExists(atPath: fromURL.path) else {
                failures.append(.init(path: entry.toPath, reason: "moved file is gone"))
                continue
            }
            guard !FileManager.default.fileExists(atPath: backURL.path) else {
                failures.append(.init(path: entry.toPath, reason: "the original spot is occupied"))
                continue
            }
            do {
                try FileManager.default.createDirectory(
                    at: backURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: fromURL, to: backURL)
            } catch {
                failures.append(.init(path: entry.toPath, reason: error.localizedDescription))
                continue
            }
            try? catalog.updateAppliedPath(fileID: entry.fileID,
                                           fromPath: entry.toPath,
                                           toPath: entry.fromPath)
            undone.append(entry)
            restored += 1
        }

        if !undone.isEmpty, restored == entries.count {
            try? catalog.deleteApplyBatch(batchID: batchID)
        }
        return UndoOutcome(batchID: batchID, restored: restored, failures: failures)
    }

    // MARK: - Internals

    /// "Report.pdf" existing -> "Report 2.pdf", "Report 3.pdf", …
    static func conflictFreeDestination(for fileName: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        for counter in 2...10_000 {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(base) \(UUID().uuidString).\(ext)")
    }
}

private extension SourceBroker {
    /// Pure-path containment check with the broker's no-symlink-escape rules.
    /// The appler never opens anything through this — moves go through the
    /// lease — it just double-checks that a catalog path still belongs to the
    /// authorized root before touching it.
    func pathIsInsideScope(_ path: String, under root: String) -> Bool {
        SourceBroker.isPath(path, under: root)
    }
}
