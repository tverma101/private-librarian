import Foundation

/// Scan-time capability used to prime a few image vectors before the normal
/// per-file Indexer path reaches `embedImageBytes`. The cache is content-keyed,
/// so a file that changes after prefetch simply misses and falls back to fresh
/// single-image inference instead of committing a stale vector.
public protocol PrefetchingBatchImageEmbeddingProvider: BatchImageEmbeddingProvider {
    var preferredBatchSize: Int { get }
    @discardableResult
    func primeImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval
    ) -> [SpecialistImageEmbeddingBatchResult]?
    func clearPrefetchedImages()
}

/// Thin content-addressed cache around the measured SigLIP2 batch worker.
///
/// The wrapped provider owns the one SpecialistModelBridge used for batch,
/// single-image, and joint-text inference, so batching never creates a second
/// Python/model process. Cached source bytes are bounded by the worker's 64-MiB
/// aggregate batch ceiling and are removed as soon as Indexer consumes them.
public final class PrefetchingSigLIP2EmbeddingProvider: PrefetchingBatchImageEmbeddingProvider, @unchecked Sendable {
    private let base: SpecialistSigLIP2EmbeddingProvider
    private let cacheLock = NSLock()
    private var prefetched: [Data: [EmbeddingVector]] = [:]

    public init(model: LocalModelDescriptor,
                bridge: SpecialistModelBridge = SpecialistModelBridge()) {
        self.base = SpecialistSigLIP2EmbeddingProvider(model: model, bridge: bridge)
    }

    public var providerID: String { base.providerID }
    public var preflight: EmbeddingProviderPreflight { base.preflight }
    public var imageModelID: String { base.imageModelID }
    public var textModelID: String { base.textModelID }
    public var model: LocalModelDescriptor { base.model }

    /// Hosted Apple-silicon MPS measurements showed Base gains most of its
    /// throughput by batch 4 with negligible additional driver allocation;
    /// So400m is an escalation path where batch 2 captures the useful gain.
    /// These are bounded defaults, not claims about exact M4 throughput.
    public var preferredBatchSize: Int {
        model.id == LocalModelStack.siglip2Base.id ? 4 : 2
    }

    public func embedText(_ text: String) -> EmbeddingVector? {
        base.embedText(text)
    }

    public func embedJointText(_ text: String) -> EmbeddingVector? {
        base.embedJointText(text)
    }

    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        cacheLock.lock()
        if var vectors = prefetched.removeValue(forKey: bytes), let first = vectors.first {
            vectors.removeFirst()
            if !vectors.isEmpty { prefetched[bytes] = vectors }
            cacheLock.unlock()
            return first
        }
        cacheLock.unlock()
        return base.embedImageBytes(bytes)
    }

    public func embedImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval = 60
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        base.embedImageBatch(items, timeout: timeout)
    }

    @discardableResult
    public func primeImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval = 60
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        guard let results = base.embedImageBatch(items, timeout: timeout),
              results.count == items.count else { return nil }

        cacheLock.lock()
        defer { cacheLock.unlock() }
        for (item, result) in zip(items, results) {
            guard item.id == result.id else {
                prefetched.removeAll(keepingCapacity: false)
                return nil
            }
            prefetched[item.bytes, default: []].append(result.vector)
        }
        return results
    }

    public func clearPrefetchedImages() {
        cacheLock.lock()
        prefetched.removeAll(keepingCapacity: false)
        cacheLock.unlock()
    }
}
