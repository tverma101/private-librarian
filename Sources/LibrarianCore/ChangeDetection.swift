import Foundation

/// Incremental indexing (plan §33): a file is reprocessed only when its
/// identity fingerprint (size, mtime) or the extractor/model versions change.
public enum ChangeDetection {

    public static let extractorVersion = "extractors-1.0.0"
    public static let classifierVersion = "rule-based-v1"

    /// Decide whether a file needs (re)indexing given its stored record.
    public static func needsProcessing(stored: (size: Int64, mtime: Double, status: String, lastExtractor: String?),
                                       current: FileIdentity) -> Bool {
        if stored.status == "missing" { return true }
        if stored.status != "indexed" { return true }
        if stored.lastExtractor != extractorVersion { return true }
        let storedM = stored.mtime
        let curM = current.mtime.timeIntervalSince1970
        return stored.size != current.size || abs(storedM - curM) > 0.001
    }
}
