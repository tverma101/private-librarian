import Foundation

/// Classifies one known catalog row against the live filesystem without
/// touching extraction or local models. Only definitive evidence may declare a
/// row missing: the path resolving to nothing (ENOENT/ENOTDIR), or the path no
/// longer naming a regular file. Permission trouble and other transient errors
/// are reported separately so callers keep the row's status and back off.
///
/// Deliberately NOT compared: `FileID`. It is path-derived, so an ID mismatch
/// would flag alias differences (`/tmp` vs `/private/tmp` bookmark resolution)
/// as deletions. A modified file at the same path still exists — its row
/// refreshes in place on the next analysis, which is the FileID contract.
public enum SourceReconciler {
    public enum Outcome: Sendable, Equatable {
        /// The path still resolves to a regular file.
        case current
        /// Definitively gone or no longer a regular file: safe to mark missing.
        case movedOrDeleted
        /// Access was refused (EACCES/EPERM). Callers should record an access
        /// backoff entry and retry later, never treat this as a deletion.
        case permissionDenied
        /// Any other transient failure while checking (I/O errors, unknown
        /// broker failures). Callers keep the row as-is.
        case unavailable
    }

    /// - Parameters:
    ///   - leaseTargetURL: the row's path mapped into an authorized lease
    ///     scope; `nil` means the row cannot be checked right now.
    ///   - identity: throws `BrokerError` exactly like `SourceBroker.identity(at:)`.
    public static func classify(
        leaseTargetURL: URL?,
        identity: (String) throws -> FileIdentity
    ) -> Outcome {
        guard let leaseTargetURL else { return .unavailable }
        do {
            _ = try identity(leaseTargetURL.path)
            return .current
        } catch BrokerError.openFailed(let errno) where errno == ENOENT || errno == ENOTDIR {
            return .movedOrDeleted
        } catch BrokerError.statFailed(let errno) where errno == ENOENT || errno == ENOTDIR {
            return .movedOrDeleted
        } catch let error as BrokerError {
            switch error {
            case .openFailed(let errno), .statFailed(let errno):
                if errno == EACCES || errno == EPERM { return .permissionDenied }
                return .unavailable
            case .isSymlink, .notRegularFile:
                // The path exists but is no longer the regular file the row
                // describes, so the known row is stale either way.
                return .movedOrDeleted
            case .snapshotTooLarge, .changedDuringRead:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}
