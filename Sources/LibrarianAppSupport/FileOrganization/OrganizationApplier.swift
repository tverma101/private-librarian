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
            /// Catalog-space destination selected during preview. Apply must
            /// use this exact path so conflict renames cannot surprise the user.
            public let toPath: String
        }

        public let id: String
        public let groupID: String
        public let groupTitle: String
        public let folderName: String
        public let destinationRootPath: String
        /// Authorized roots represented by this group, offered to the user as
        /// destination choices. The selected root remains deterministic by default.
        public let candidateRootPaths: [String]
        public let items: [Item]
        public let missingPaths: [String]
        public let skippedOtherRoots: Int
        /// Members that already live inside this group's destination folder.
        /// Re-applying is a no-op for them, so the sheet can say so instead of
        /// opening a dead "Move 0 Files" confirmation.
        public let alreadyInPlace: Int

        /// Catalog-space destination folder path (what the user will see).
        public var destinationFolderPath: String {
            destinationRootPath + "/" + folderName
        }

        /// Return the same preview after the user deselects individual files.
        /// Keeping the plan ID preserves one journal batch for the confirmation.
        public func excluding(fileIDs: Set<String>) -> Plan {
            Plan(id: id,
                 groupID: groupID,
                 groupTitle: groupTitle,
                 folderName: folderName,
                 destinationRootPath: destinationRootPath,
                 candidateRootPaths: candidateRootPaths,
                 items: items.filter { !fileIDs.contains($0.fileID) },
                 missingPaths: missingPaths,
                 skippedOtherRoots: skippedOtherRoots,
                 alreadyInPlace: alreadyInPlace)
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
        case destinationCreateFailed(path: String, reason: String)
        case journalPersistenceFailed(reason: String, rollbackFailures: [Outcome.Failure])

        public var errorDescription: String? {
            switch self {
            case .noMembers:
                return "This group has no movable files."
            case .noAuthorizedRoot:
                return "The folder holding these files is no longer authorized. Re-authorize it and try again."
            case let .destinationCreateFailed(path, reason):
                return "Could not create the destination folder at \(path): \(reason)"
            case let .journalPersistenceFailed(reason, rollbackFailures):
                if rollbackFailures.isEmpty {
                    return "The move was rolled back because its recovery record could not be saved: \(reason)"
                }
                return "The recovery record could not be saved and \(rollbackFailures.count) moved file(s) could not be restored. Review recovery before trying again."
            }
        }
    }

    // MARK: - Planning

    /// Build a preview plan. `pathFor` resolves catalog file IDs to recorded
    /// source paths; `sourceRoots` are the currently authorized roots.
    public static func plan(
        group: SmartOrganizationGroup,
        pathFor: (String) -> String,
        sourceRoots: [String],
        destinationRootPath requestedDestinationRoot: String? = nil
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
        let destinationRoot: String
        if let requestedDestinationRoot,
           byRoot[requestedDestinationRoot] != nil {
            destinationRoot = requestedDestinationRoot
        } else if let inferredRoot = byRoot.max(by: {
            if $0.value.count != $1.value.count { return $0.value.count < $1.value.count }
            return $0.key > $1.key
        })?.key {
            destinationRoot = inferredRoot
        } else {
            throw ApplyError.noAuthorizedRoot
        }

        // Every near-duplicate family shares the same title; without a suffix,
        // applying two families into one root would silently merge both into
        // a single "Near-duplicate family" folder.
        var folderName = sanitizedFolderName(from: group.title)
        if group.kind == .nearDuplicate {
            let compact = group.id.filter { $0.isLetter || $0.isNumber }
            if !compact.isEmpty {
                folderName = String(folderName.prefix(72)) + " " + String(compact.suffix(6))
            }
        }
        let destinationMembers = byRoot[destinationRoot] ?? []
        var missingPaths: [String] = []
        var items: [Plan.Item] = []
        var alreadyInPlace = 0
        var reservedDestinationNames: Set<String> = []
        let destinationPath = destinationRoot + "/" + folderName
        let broker = SourceBroker()
        for member in destinationMembers {
            // Applying the same group again must be a no-op for files already
            // inside its destination, not a path-nesting operation.
            guard !SourceBroker.isPath(member.path, under: destinationPath) else {
                alreadyInPlace += 1
                continue
            }
            guard broker.isRegularFile(at: member.path) else {
                missingPaths.append(member.path)
                continue
            }
            let fileName = URL(fileURLWithPath: member.path).lastPathComponent
            let targetURL = conflictFreeDestination(
                for: fileName,
                in: URL(fileURLWithPath: destinationPath, isDirectory: true),
                reservedNames: &reservedDestinationNames)
            items.append(Plan.Item(fileID: member.fileID,
                                   fromPath: member.path,
                                   toPath: destinationPath + "/" + targetURL.lastPathComponent))
        }
        let skippedOtherRoots = members.count - destinationMembers.count
        return Plan(
            id: UUID().uuidString,
            groupID: group.id,
            groupTitle: group.title,
            folderName: folderName,
            destinationRootPath: destinationRoot,
            candidateRootPaths: byRoot.keys.sorted(),
            items: items,
            missingPaths: missingPaths.sorted(),
            skippedOtherRoots: skippedOtherRoots,
            alreadyInPlace: alreadyInPlace)
    }

    /// Folder names stay single-level and filesystem-safe.
    static func sanitizedFolderName(from title: String) -> String {
        var name = title
        for separator in ["/", ":", "\0"] where name.contains(separator) {
            name = name.replacingOccurrences(of: separator, with: " ")
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Organized files" }
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
            throw ApplyError.destinationCreateFailed(
                path: plan.destinationFolderPath,
                reason: error.localizedDescription)
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
            guard broker.isRegularFile(at: sourceURL.path) else {
                failures.append(.init(path: item.fromPath,
                                      reason: "source is missing, a directory, or a symlink"))
                continue
            }
            guard let targetURL = lease.targetURL(
                for: item.toPath,
                originalRootPath: plan.destinationRootPath),
                  SourceBroker.isPath(item.toPath, under: plan.destinationFolderPath),
                  !FileManager.default.fileExists(atPath: targetURL.path) else {
                failures.append(.init(path: item.fromPath,
                                      reason: "destination changed since preview"))
                continue
            }
            guard targetURL.lastPathComponent == URL(fileURLWithPath: item.toPath).lastPathComponent else {
                failures.append(.init(path: item.fromPath,
                                      reason: "planned destination could not be resolved"))
                continue
            }
            do {
                try FileManager.default.moveItem(at: sourceURL, to: targetURL)
            } catch {
                failures.append(.init(path: item.fromPath, reason: error.localizedDescription))
                continue
            }
            journal.append(.init(fileID: item.fileID, fromPath: item.fromPath, toPath: item.toPath))
            moved += 1
        }

        // The filesystem has already changed, so a journal-write failure must
        // not leave an un-undoable batch behind. Roll successful moves back
        // before returning the catalog error.
        if !journal.isEmpty {
            do {
                try catalog.recordApplyBatch(batchID: batchID,
                                             appliedAt: Date().timeIntervalSince1970,
                                             entries: journal)
            } catch {
                var rollbackFailures: [Outcome.Failure] = []
                for entry in journal.reversed() {
                    guard let sourceURL = lease.targetURL(for: entry.toPath,
                                                          originalRootPath: plan.destinationRootPath),
                          let targetURL = lease.targetURL(for: entry.fromPath,
                                                          originalRootPath: plan.destinationRootPath) else {
                        rollbackFailures.append(.init(path: entry.toPath,
                                                      reason: "rollback path is outside the authorized folder"))
                        continue
                    }
                    guard broker.isRegularFile(at: sourceURL.path) else {
                        rollbackFailures.append(.init(path: entry.toPath,
                                                      reason: "moved file was not available during rollback"))
                        continue
                    }
                    do {
                        guard !FileManager.default.fileExists(atPath: targetURL.path) else {
                            throw CocoaError(.fileWriteFileExists)
                        }
                        try FileManager.default.createDirectory(
                            at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    } catch {
                        rollbackFailures.append(.init(path: entry.toPath,
                                                      reason: "rollback failed: \(error.localizedDescription)"))
                    }
                }
                throw ApplyError.journalPersistenceFailed(
                    reason: error.localizedDescription,
                    rollbackFailures: rollbackFailures)
            }
            for entry in journal {
                do {
                    guard try catalog.updateAppliedPath(fileID: entry.fileID,
                                                        fromPath: entry.fromPath,
                                                        toPath: entry.toPath) else {
                        failures.append(.init(path: entry.toPath,
                                              reason: "catalog row changed before the move was recorded"))
                        continue
                    }
                } catch {
                    failures.append(.init(path: entry.toPath,
                                          reason: "catalog update failed: \(error.localizedDescription)"))
                }
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
                .max(by: {
                    if $0.count != $1.count { return $0.count < $1.count }
                    return $0 > $1
                })
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
            do {
                guard try catalog.updateAppliedPath(fileID: entry.fileID,
                                                    fromPath: entry.toPath,
                                                    toPath: entry.fromPath) else {
                    failures.append(.init(path: entry.toPath,
                                          reason: "catalog row changed before Undo could be recorded"))
                    continue
                }
            } catch {
                failures.append(.init(path: entry.toPath,
                                      reason: "catalog update failed: \(error.localizedDescription)"))
                continue
            }
            undone.append(entry)
            restored += 1
        }

        if !undone.isEmpty, restored == entries.count, failures.isEmpty {
            try? catalog.deleteApplyBatch(batchID: batchID)
            removeDestinationFolderIfEmpty(entries: entries, leaseForRoot: leaseForRoot, rootFor: rootFor)
        }
        return UndoOutcome(batchID: batchID, restored: restored, failures: failures)
    }

    /// Best-effort: after Undo restores every file, the destination folder the
    /// apply created would otherwise linger as an empty surprise in the user's
    /// source root. Only removed when every entry shared one folder and that
    /// folder is now completely empty — any other content keeps it.
    private static func removeDestinationFolderIfEmpty(
        entries: [Catalog.ApplyJournalEntry],
        leaseForRoot: (String) throws -> any OrganizationLease,
        rootFor: (String) -> String?
    ) {
        let parents = Set(entries.map { ($0.toPath as NSString).deletingLastPathComponent })
        guard parents.count == 1, let folderPath = parents.first else { return }
        guard let root = rootFor(folderPath),
              let lease = try? leaseForRoot(root),
              let folderURL = lease.targetURL(for: folderPath, originalRootPath: root) else { return }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: folderURL.path)) ?? ["keep"]
        guard contents.isEmpty else { return }
        try? FileManager.default.removeItem(at: folderURL)
    }

    // MARK: - Internals

    /// "Report.pdf" existing -> "Report 2.pdf", "Report 3.pdf", …
    static func conflictFreeDestination(for fileName: String, in directory: URL) -> URL {
        var reservedNames: Set<String> = []
        return conflictFreeDestination(for: fileName,
                                       in: directory,
                                       reservedNames: &reservedNames)
    }

    private static func conflictFreeDestination(
        for fileName: String,
        in directory: URL,
        reservedNames: inout Set<String>) -> URL {
        func isAvailable(_ name: String) -> Bool {
            !reservedNames.contains(name)
                && !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(name).path)
        }

        var candidateName = fileName
        if !isAvailable(candidateName) {
            let base = (fileName as NSString).deletingPathExtension
            let ext = (fileName as NSString).pathExtension
            for counter in 2...10_000 {
                let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                if isAvailable(name) {
                    candidateName = name
                    break
                }
            }
            if !isAvailable(candidateName) {
                candidateName = ext.isEmpty
                    ? "\(base) \(UUID().uuidString)"
                    : "\(base) \(UUID().uuidString).\(ext)"
            }
        }
        reservedNames.insert(candidateName)
        return directory.appendingPathComponent(candidateName)
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
