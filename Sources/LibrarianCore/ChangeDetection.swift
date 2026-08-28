import Foundation

/// Incremental indexing (plan §33): a file is reprocessed only when its
/// identity fingerprint (size, mtime), processing version, or state changes.
public enum ChangeDetection {

    public static let extractorVersion = "extractors-1.0.0"
    public static let classifierVersion = "rule-based-v2-screenshot-ocr"

    /// Decide whether a file needs (re)indexing given its stored record.
    /// `requiredExtractorVersion` is the complete processing-pipeline identity
    /// chosen by Indexer (extractors + classifier + Vision + optional Tier 2).
    public static func needsProcessing(
        stored: (size: Int64, mtime: Double, status: String, lastExtractor: String?),
        current: FileIdentity,
        requiredExtractorVersion: String = extractorVersion
    ) -> Bool {
        if stored.status == "missing" { return true }

        // A cloud placeholder is a stable terminal state just like indexed:
        // if it is still the same placeholder and the pipeline version did not
        // change, do not repeatedly revisit it. Pending/failed/race states must
        // always be retried.
        if stored.status != "indexed" && stored.status != "cloud-placeholder" {
            return true
        }

        if stored.lastExtractor != requiredExtractorVersion { return true }

        let storedM = stored.mtime
        let curM = current.mtime.timeIntervalSince1970
        return stored.size != current.size || abs(storedM - curM) > 0.001
    }
}
