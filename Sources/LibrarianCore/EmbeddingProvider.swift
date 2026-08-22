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

// MARK: - Core ML MobileCLIP experiment provider (Issue #11)

public struct CoreMLMobileCLIPProvider: EmbeddingProvider {
    public static let preprocessingRevision = "mclip-prep-v1:resize224-centerCrop-normalize0.5-tokenBPE77"
    public static let checkpointID = "mobileclip-s0:71aa3e13"
    public static let dimension = 512
    public let providerID: String
    public init() {
        let h = Self.hashPreprocessing(Self.preprocessingRevision)
        self.providerID = "coreml-mobileclip-s0:\(Self.checkpointID):prep-\(h)"
    }
    public static var isAvailable: Bool {
        for root in LocalModelBridge.modelsRoots() {
            let base = root.appendingPathComponent("mobileclip-s0")
            if FileManager.default.fileExists(atPath: base.appendingPathComponent("config.json").path) { return true }
            let coremlDir = root.appendingPathComponent("mobileclip-s0-coreml")
            if FileManager.default.fileExists(atPath: coremlDir.path) {
                let fm = FileManager.default
                if let kids = try? fm.contentsOfDirectory(atPath: coremlDir.path),
                   kids.contains(where: { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") || $0.hasSuffix(".mlmodel") }) { return true }
                return true
            }
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("mobileclip-s0-coreml"),
           FileManager.default.fileExists(atPath: res.path) { return true }
        return false
    }
    static func hashPreprocessing(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }
    public func embedText(_ text: String) -> EmbeddingVector? { embedJointText(text) }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        guard !bytes.isEmpty else { return nil }
        guard Self.isAvailable else { return nil }
        if let vec = Self.tryCoreMLImageEmbedding(bytes: bytes) {
            return EmbeddingVector(spaceID: Self.jointSpaceID, dim: Self.dimension, data: vec)
        }
        return nil
    }
    public func embedJointText(_ text: String) -> EmbeddingVector? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        guard Self.isAvailable else { return nil }
        if let vec = Self.tryCoreMLTextEmbedding(text: String(t.prefix(4000))) {
            return EmbeddingVector(spaceID: Self.jointSpaceID, dim: Self.dimension, data: vec)
        }
        return nil
    }
    public static var jointSpaceID: String { "mclip-joint:\(Indexer.embeddingSpaceVersion):\(preprocessingRevision)" }
    private static func tryCoreMLImageEmbedding(bytes: Data) -> Data? {
        #if canImport(CoreML)
        return nil
        #else
        return nil
        #endif
    }
    private static func tryCoreMLTextEmbedding(text: String) -> Data? {
        #if canImport(CoreML)
        return nil
        #else
        return nil
        #endif
    }
    static func coremlModelURL(kind: String) -> URL? {
        let f: String = (kind == "image") ? "MobileCLIPImageEncoder.mlpackage" : "MobileCLIPTextEncoder.mlpackage"
        for root in LocalModelBridge.modelsRoots() {
            let u = root.appendingPathComponent("mobileclip-s0-coreml").appendingPathComponent(f)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        if let res = Bundle.main.resourceURL?.appendingPathComponent("mobileclip-s0-coreml").appendingPathComponent(f),
           FileManager.default.fileExists(atPath: res.path) { return res }
        return nil
    }
}

public enum EmbeddingProviderFactory: Sendable {
    public static func make(kind: String) -> any EmbeddingProvider {
        switch kind.lowercased() {
        case "coreml", "coreml-mobileclip", "mobileclip", "mclip":
            let p = CoreMLMobileCLIPProvider()
            if CoreMLMobileCLIPProvider.isAvailable { return p }
            return LocalModelEmbeddingProvider()
        case "disabled", "off", "none":
            return DisabledEmbeddingProvider()
        default:
            return LocalModelEmbeddingProvider(providerID: "local-model-bridge-v1:\(kind)")
        }
    }
    public static func availableProviders() -> [String] {
        var ids: [String] = ["local-model-bridge-v1", "disabled"]
        if CoreMLMobileCLIPProvider.isAvailable { ids.append(CoreMLMobileCLIPProvider().providerID) }
        else { ids.append("coreml-mobileclip-s0 (not provisioned — will fallback)") }
        return ids
    }
}

