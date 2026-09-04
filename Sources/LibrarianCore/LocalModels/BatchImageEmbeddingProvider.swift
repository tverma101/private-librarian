import Foundation

/// Optional capability for providers that can execute a true grouped image
/// inference call. Keeping batching out of the base `EmbeddingProvider`
/// contract means Core ML, legacy Python, and test providers remain unchanged;
/// the scan coordinator can opt in only when this capability is present.
public protocol BatchImageEmbeddingProvider: EmbeddingProvider {
    func embedImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval
    ) -> [SpecialistImageEmbeddingBatchResult]?
}

/// SigLIP2 is currently the only production provider with a measured grouped
/// worker path. The implementation lives on the concrete provider so it shares
/// the exact same long-lived SpecialistModelBridge/worker as single-image and
/// joint-text inference; no duplicate model process is created.
extension SpecialistSigLIP2EmbeddingProvider: BatchImageEmbeddingProvider {}
