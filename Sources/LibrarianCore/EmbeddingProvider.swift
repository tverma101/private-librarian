import Foundation

/// Backend-neutral embedding contract.
///
/// Indexing/search should depend on this surface rather than a concrete Python,
/// Core ML, Vision, or future MLX implementation. Providers receive derived
/// text or broker-supplied bytes only; they never receive source-file authority.
public struct EmbeddingVector: Sendable, Equatable {
    public let spaceID: String
    public let dim: Int
    public let data: Data

    public init(spaceID: String, dim: Int, data: Data) {
        self.spaceID = spaceID
        self.dim = dim
        self.data = data
    }
}

public protocol EmbeddingProvider: Sendable {
    /// Stable identity of implementation + checkpoint + preprocessing contract.
    var providerID: String { get }

    /// General semantic text space, if supported.
    func embedText(_ text: String) -> EmbeddingVector?

    /// Image embedding from bytes already read through SourceBroker.
    func embedImageBytes(_ bytes: Data) -> EmbeddingVector?

    /// Text embedding in the same cross-modal space as image vectors, if supported.
    func embedJointText(_ text: String) -> EmbeddingVector?
}

/// Adapter around the current local Python-backed bridge.
/// Keeps legacy functionality available while native providers are benchmarked.
public struct LocalModelEmbeddingProvider: EmbeddingProvider {
    public let providerID: String

    public init(providerID: String = "local-model-bridge-v1") {
        self.providerID = providerID
    }

    public func embedText(_ text: String) -> EmbeddingVector? {
        guard let result = LocalModelBridge.embedText(text), !result.data.isEmpty else { return nil }
        return EmbeddingVector(
            spaceID: "minilm:\(Indexer.embeddingSpaceVersion)",
            dim: result.dim,
            data: result.data
        )
    }

    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        guard let result = LocalModelBridge.embedImageBytes(bytes), !result.data.isEmpty else { return nil }
        return EmbeddingVector(
            spaceID: "clip-image:\(Indexer.embeddingSpaceVersion)",
            dim: result.dim,
            data: result.data
        )
    }

    public func embedJointText(_ text: String) -> EmbeddingVector? {
        guard let result = LocalModelBridge.embedClipText(text), !result.data.isEmpty else { return nil }
        return EmbeddingVector(
            spaceID: "clip-joint:\(Indexer.embeddingSpaceVersion)",
            dim: result.dim,
            data: result.data
        )
    }
}

/// Deliberate no-op provider for Tier-1-only installs and tests.
public struct DisabledEmbeddingProvider: EmbeddingProvider {
    public let providerID = "disabled"
    public init() {}
    public func embedText(_ text: String) -> EmbeddingVector? { nil }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? { nil }
    public func embedJointText(_ text: String) -> EmbeddingVector? { nil }
}
