import Foundation

/// Incremental indexing (plan §33): a file is reprocessed only when its
/// identity fingerprint (size, mtime), processing version, or state changes.
public enum ChangeDetection {

    public static let extractorVersion = "extractors-1.0.0"
    /// v6 keeps the v5 content-first resolver but constrains ambient sibling/
    /// cluster context to ambiguous, compatible files. Opaque archives and
    /// installer-like bundles cannot inherit unrelated semantic destinations
    /// from neighboring files, and strong local semantic evidence cannot be
    /// overridden by folder population. Existing catalogs must reclassify once
    /// so any v5 contextual contamination is removed.
    public static let classifierVersion = "rule-based-v6-context-compatibility"

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
