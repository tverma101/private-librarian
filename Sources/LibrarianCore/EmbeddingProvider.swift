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

/// A provider decision is deliberately explicit. `available == false` means
/// callers may fall back, but must not describe the provider as active.
public struct EmbeddingProviderPreflight: Sendable, Equatable {
    public let providerID: String
    public let available: Bool
    public let reason: String
    public let artifacts: [String]
    public let dependencies: [String]

    public init(providerID: String, available: Bool, reason: String,
                artifacts: [String] = [], dependencies: [String] = []) {
        self.providerID = providerID
        self.available = available
        self.reason = reason
        self.artifacts = artifacts
        self.dependencies = dependencies
    }
}

public protocol EmbeddingProvider: Sendable {
    /// Stable identity of implementation + checkpoint + preprocessing contract.
    var providerID: String { get }
    var preflight: EmbeddingProviderPreflight { get }
    /// Catalog keys for each modality. They include provider identity by
    /// default so vectors from a changed checkpoint cannot share a namespace.
    var imageModelID: String { get }
    var textModelID: String { get }

    /// General semantic text space, if supported.
    func embedText(_ text: String) -> EmbeddingVector?

    /// Image embedding from bytes already read through SourceBroker.
    func embedImageBytes(_ bytes: Data) -> EmbeddingVector?

    /// Text embedding in the same cross-modal space as image vectors, if supported.
    func embedJointText(_ text: String) -> EmbeddingVector?
}

public extension EmbeddingProvider {
    var imageModelID: String { "image:\(providerID)" }
    var textModelID: String { "text:\(providerID)" }
}

/// Adapter around the current local Python-backed bridge.
/// Keeps legacy functionality available while native providers are benchmarked.
public struct LocalModelEmbeddingProvider: EmbeddingProvider {
    public static let clipPreprocessing = "transformers-clip:v1:resize224-centerCrop-normalize(mean=0.48145466,0.4578275,0.40821073;std=0.26862954,0.26130258,0.27577711)"
    public static let textPreprocessing = "sentence-transformers:minilm-l6-v2:v1:truncate4000-normalize"
    public let providerID: String

    public var imageModelID: String { "image:\(providerID)" }
    public var textModelID: String { "text:\(providerID)" }

    public init(providerID: String = "local-model-bridge-v1") {
        self.providerID = providerID == "local-model-bridge-v1"
            ? "python-transformers:clip-vit-base-patch32@3d74acf9:\(Self.clipPreprocessing)|minilm-l6-v2@1110a243:\(Self.textPreprocessing)"
            : providerID
    }

    public var preflight: EmbeddingProviderPreflight {
        let clip = LocalModelBridge.isProvisioned(.clipImage)
        let mini = LocalModelBridge.isProvisioned(.miniLMText)
        let runtime = (clip || mini) && LocalModelBridge.isAvailable()
        let reason: String
        if !clip && !mini {
            reason = "No provisioned Python checkpoint under the configured Models roots."
        } else if !runtime {
            reason = "Checkpoint artifacts are present, but the offline Python runtime/dependencies are unavailable."
        } else if clip && mini {
            reason = "Python checkpoints and the offline runtime are ready."
        } else {
            reason = "One Python checkpoint and the offline runtime are ready."
        }
        return EmbeddingProviderPreflight(
            providerID: providerID,
            available: runtime,
            reason: reason,
            artifacts: [LocalModelBridge.Model.clipImage.rawValue, LocalModelBridge.Model.miniLMText.rawValue],
            dependencies: ["python3", "torch", "transformers", "PIL", "numpy", "sentence_transformers"])
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
    public var preflight: EmbeddingProviderPreflight {
        EmbeddingProviderPreflight(providerID: providerID, available: true, reason: "Explicitly disabled")
    }
    public func embedText(_ text: String) -> EmbeddingVector? { nil }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? { nil }
    public func embedJointText(_ text: String) -> EmbeddingVector? { nil }
}

/// A requested provider that is not installed must remain unavailable. This
/// preserves the operator's provider choice and prevents an implicit switch
/// to a different model space or runtime.
public struct UnavailableEmbeddingProvider: EmbeddingProvider {
    public let providerID: String
    public let reason: String

    public init(providerID: String, reason: String) {
        self.providerID = providerID
        self.reason = reason
    }

    public var preflight: EmbeddingProviderPreflight {
        EmbeddingProviderPreflight(providerID: providerID, available: false, reason: reason)
    }

    public func embedText(_ text: String) -> EmbeddingVector? { nil }
    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? { nil }
    public func embedJointText(_ text: String) -> EmbeddingVector? { nil }
}

// MARK: - Genuine Core ML MobileCLIP S0 provider (Issue #11 / #31)

public struct CoreMLMobileCLIPProvider: EmbeddingProvider {
    public static let preprocessingRevision = "mclip-s0-prep-v1:CoreML-256x256-ARGB-tokenBPE77"
    public static let checkpointID = "apple/coreml-mobileclip@3e0a7bfb"
    public static let dimension = 512
    public let providerID: String

    public var imageModelID: String { "image:\(providerID)" }
    public var textModelID: String { "text:\(providerID)" }

    public init() {
        let h = Self.hashPreprocessing(Self.preprocessingRevision)
        self.providerID = "coreml-mobileclip-s0:\(Self.checkpointID):prep-\(h)"
    }

    public static var preflight: EmbeddingProviderPreflight {
        let id = CoreMLMobileCLIPProvider().providerID
        let image = coremlModelURL(kind: "image")
        let text = coremlModelURL(kind: "text")
        let root = coremlModelRoot()
        let provenance = root.map { trustedCoreMLProvenance($0) } ?? false
        let tokenizer = root.map {
            MobileCLIPTokenizer(modelRoots: [$0] + LocalModelBridge.modelsRoots()) != nil
        } ?? false
        let artifacts = [image, text].compactMap { $0?.path }
        let reason: String
        #if canImport(CoreML)
        if image == nil || text == nil {
            reason = coremlUncompiledModelURLs().isEmpty
                ? "Compiled MobileCLIP S0 image and text .mlmodelc artifacts are required."
                : "MobileCLIP .mlpackage artifacts are present but must be compiled with xcrun coremlcompiler first."
        } else if !provenance {
            reason = "Compiled MobileCLIP artifacts are missing a trusted pinned provenance manifest."
        } else if !tokenizer {
            reason = "Compiled model pair is present, but CLIP vocab.json and merges.txt are missing."
        } else {
            reason = "Genuine MobileCLIP S0 Core ML image/text runtime is available."
        }
        #else
        reason = "CoreML is unavailable in this build."
        #endif
        return EmbeddingProviderPreflight(
            providerID: id,
            available: image != nil && text != nil && tokenizer && provenance,
            reason: reason,
            artifacts: artifacts,
            dependencies: ["CoreML", "MobileCLIP S0 image encoder", "MobileCLIP S0 text encoder", "CLIP BPE vocabulary"])
    }

    public static var isAvailable: Bool { preflight.available }
    public var preflight: EmbeddingProviderPreflight { Self.preflight }

    static func hashPreprocessing(_ s: String) -> String {
        var h: UInt64 = 1469598103934665603
        for b in s.utf8 { h ^= UInt64(b); h = h &* 1099511628211 }
        return String(format: "%08x", UInt32(truncatingIfNeeded: h))
    }

    public func embedText(_ text: String) -> EmbeddingVector? { embedJointText(text) }

    public func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        guard !bytes.isEmpty, Self.isAvailable,
              let vec = Self.runtime.embedImage(bytes: bytes) else { return nil }
        return EmbeddingVector(spaceID: Self.jointSpaceID, dim: Self.dimension, data: vec)
    }

    public func embedJointText(_ text: String) -> EmbeddingVector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, Self.isAvailable,
              let vec = Self.runtime.embedText(String(trimmed.prefix(4000))) else { return nil }
        return EmbeddingVector(spaceID: Self.jointSpaceID, dim: Self.dimension, data: vec)
    }

    public static var jointSpaceID: String {
        "mclip-joint:\(Indexer.embeddingSpaceVersion):\(preprocessingRevision)"
    }

    #if canImport(CoreML)
    private static let runtime = MobileCLIPRuntime()
    #else
    private static let runtime = UnavailableMobileCLIPRuntime()
    #endif

    static func coremlModelURL(kind: String) -> URL? {
        let file = kind == "image" ? "mobileclip_s0_image.mlmodelc" : "mobileclip_s0_text.mlmodelc"
        return coremlModelRootCandidates().map { $0.appendingPathComponent(file) }
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func coremlModelRoot() -> URL? {
        guard let image = coremlModelURL(kind: "image"),
              let text = coremlModelURL(kind: "text") else { return nil }
        let imageRoot = image.deletingLastPathComponent()
        return imageRoot == text.deletingLastPathComponent() ? imageRoot : nil
    }

    private static func trustedCoreMLProvenance(_ directory: URL) -> Bool {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("provenance.json")),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["coreml_repo"] as? String == "apple/coreml-mobileclip",
              record["coreml_revision"] as? String == "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
              record["tokenizer_repo"] as? String == "openai/clip-vit-base-patch32",
              record["tokenizer_revision"] as? String == "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268",
              let files = record["files_sha256"] as? [String: Any],
              !files.isEmpty else { return false }

        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let requiredPrefixes = [
            "mobileclip_s0_image.mlpackage/",
            "mobileclip_s0_text.mlpackage/",
            "mobileclip_s0_image.mlmodelc/",
            "mobileclip_s0_text.mlmodelc/",
            "vocab.json",
            "merges.txt",
        ]
        guard requiredPrefixes.allSatisfy({ prefix in
            files.keys.contains(where: { $0 == prefix || $0.hasPrefix(prefix) })
        }) else { return false }
        for (relative, value) in files {
            guard let expected = value as? String,
                  expected.count == 64,
                  expected.allSatisfy({ $0.isHexDigit }) else { return false }
            let path = directory.appendingPathComponent(relative)
                .resolvingSymlinksInPath().standardizedFileURL
            guard path.path == root.path || path.path.hasPrefix(root.path + "/"),
                  let values = try? path.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  LocalModelBridge.sha256File(path) == expected.lowercased() else { return false }
        }
        return true
    }

    private static func coremlModelRootCandidates() -> [URL] {
        var roots = LocalModelBridge.modelsRoots().map {
            $0.appendingPathComponent("mobileclip-s0-coreml")
        }
        if let resources = Bundle.main.resourceURL?.appendingPathComponent("mobileclip-s0-coreml") {
            roots.append(resources)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert($0.path).inserted }
    }

    private static func coremlUncompiledModelURLs() -> [URL] {
        coremlModelRootCandidates().flatMap { root in
            ["mobileclip_s0_image.mlpackage", "mobileclip_s0_text.mlpackage"].map {
                root.appendingPathComponent($0)
            }
        }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

#if canImport(CoreML)
import CoreML
import CoreGraphics
import ImageIO

private final class MobileCLIPRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private let inferenceSemaphore = DispatchSemaphore(value: 2)
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: MobileCLIPTokenizer?

    func embedImage(bytes: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let loaded = load() else { return nil }
        inferenceSemaphore.wait()
        defer { inferenceSemaphore.signal() }
        do {
            let input = try MLFeatureValue(cgImage: image, pixelsWide: 256, pixelsHigh: 256,
                                            pixelFormatType: kCVPixelFormatType_32ARGB, options: nil)
            let features = try MLDictionaryFeatureProvider(dictionary: [loaded.imageInputName: input])
            let output = try loaded.image.prediction(from: features)
            return normalizedVector(from: output, expectedDimension: CoreMLMobileCLIPProvider.dimension)
        } catch {
            return nil
        }
    }

    func embedText(_ text: String) -> Data? {
        guard let loaded = load() else { return nil }
        let tokenizer = loaded.tokenizer
        inferenceSemaphore.wait()
        defer { inferenceSemaphore.signal() }
        do {
            let tokens = tokenizer.encodeFull(text)
            let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, token) in tokens.enumerated() { array[index] = NSNumber(value: token) }
            let features = try MLDictionaryFeatureProvider(dictionary: [loaded.textInputName: MLFeatureValue(multiArray: array)])
            let output = try loaded.text.prediction(from: features)
            return normalizedVector(from: output, expectedDimension: CoreMLMobileCLIPProvider.dimension)
        } catch {
            return nil
        }
    }

    private func load() -> (image: MLModel, text: MLModel, imageInputName: String,
                             textInputName: String, tokenizer: MobileCLIPTokenizer)? {
        lock.lock()
        defer { lock.unlock() }
        if let imageModel, let textModel, let tokenizer {
            return (imageModel, textModel, imageInputName(imageModel), textInputName(textModel), tokenizer)
        }
        guard let imageURL = CoreMLMobileCLIPProvider.coremlModelURL(kind: "image"),
              let textURL = CoreMLMobileCLIPProvider.coremlModelURL(kind: "text"),
              let root = CoreMLMobileCLIPProvider.coremlModelRoot(),
              let tokenizer = MobileCLIPTokenizer(modelRoots: [root] + LocalModelBridge.modelsRoots()) else { return nil }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let image = try MLModel(contentsOf: imageURL, configuration: configuration)
            let text = try MLModel(contentsOf: textURL, configuration: configuration)
            self.imageModel = image
            self.textModel = text
            self.tokenizer = tokenizer
            return (image, text, imageInputName(image), textInputName(text), tokenizer)
        } catch {
            return nil
        }
    }

    private func imageInputName(_ model: MLModel) -> String {
        model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .image })?.key
            ?? model.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "image"
    }

    private func textInputName(_ model: MLModel) -> String {
        model.modelDescription.inputDescriptionsByName.first(where: { $0.value.type == .multiArray })?.key
            ?? model.modelDescription.inputDescriptionsByName.keys.sorted().first ?? "text"
    }

    private func normalizedVector(from provider: MLFeatureProvider, expectedDimension: Int) -> Data? {
        let output = provider.featureNames.compactMap { provider.featureValue(for: $0)?.multiArrayValue }.first
        guard let output, output.count == expectedDimension else { return nil }
        var values = [Float](repeating: 0, count: expectedDimension)
        var norm: Float = 0
        for index in 0..<expectedDimension {
            let value = output[index].floatValue
            guard value.isFinite else { return nil }
            values[index] = value
            norm += value * value
        }
        guard norm.isFinite, norm > 0 else { return nil }
        let inverse = 1 / norm.squareRoot()
        guard inverse.isFinite else { return nil }
        var data = Data(capacity: expectedDimension * MemoryLayout<Float>.stride)
        for value in values {
            var normalized = value * inverse
            guard normalized.isFinite else { return nil }
            withUnsafeBytes(of: &normalized) { data.append(contentsOf: $0) }
        }
        return data
    }
}
#else
private struct UnavailableMobileCLIPRuntime: Sendable {
    func embedImage(bytes: Data) -> Data? { nil }
    func embedText(_ text: String) -> Data? { nil }
}
#endif

public enum EmbeddingProviderFactory: Sendable {
    public static func make(kind: String) -> any EmbeddingProvider {
        switch kind.lowercased() {
        case "coreml", "coreml-mobileclip", "mobileclip", "mclip":
            let p = CoreMLMobileCLIPProvider()
            if CoreMLMobileCLIPProvider.isAvailable { return p }
            return UnavailableEmbeddingProvider(
                providerID: p.providerID,
                reason: p.preflight.reason)
        case "disabled", "off", "none":
            return DisabledEmbeddingProvider()
        default:
            return LocalModelEmbeddingProvider(providerID: "local-model-bridge-v1:\(kind)")
        }
    }
    public static func availableProviders() -> [String] {
        var ids: [String] = [LocalModelEmbeddingProvider().providerID, "disabled"]
        if CoreMLMobileCLIPProvider.isAvailable { ids.append(CoreMLMobileCLIPProvider().providerID) }
        else { ids.append("coreml-mobileclip-s0 (not provisioned — unavailable)") }
        return ids
    }
}
