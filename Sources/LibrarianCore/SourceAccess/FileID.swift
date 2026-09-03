import Foundation
import CryptoKit

/// Content-INDEPENDENT opaque file id: `file_<12 hex of SHA-256 over path>`.
///
/// Stability contract: the id is the catalog's primary key and is referenced
/// by child tables (text_content, classifications, hashes...). It must NOT
/// change when a file is modified — size/mtime/kind are attributes updated in
/// place. Deriving the id from mutable properties caused foreign-key
/// breakage on every re-index of a changed file.
///
/// The path is hashed so log lines and error records never contain it.
public enum FileID {
    public static func make(identity: FileIdentity) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(identity.path.utf8))
        let digest = hasher.finalize()
        return "file_" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public static func workerError(_ n: Int) -> String { "worker_error_\(n)" }
}
