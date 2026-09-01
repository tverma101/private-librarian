import Foundation

/// Final local specialist stack. These are capabilities, not filesystem actors:
/// models only receive broker-owned bytes or derived text and never receive a source path.
public enum LocalModelCapability: String, Codable, Sendable, CaseIterable {
    case imageSemantic
    case visualSimilarity
    case documentOCR
    case textReasoning
    case visionFallback
    case visionHeavyFallback
}

public enum LocalModelCostClass: Int, Codable, Sendable, Comparable {
    case tiny = 0
    case small = 1
    case medium = 2
    case heavy = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct LocalModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let capability: LocalModelCapability
    public let hfID: String
    /// Immutable Hub commit prefix. Provisioning resolves and records the full 40-char SHA.
    public let revisionPrefix: String
    public let license: String
    public let cost: LocalModelCostClass
    public let gated: Bool
    public let defaultEnabled: Bool
    public let runtime: String

    public init(id: String, capability: LocalModelCapability, hfID: String,
                revisionPrefix: String, license: String, cost: LocalModelCostClass,
                gated: Bool = false, defaultEnabled: Bool = false, runtime: String) {
        self.id = id
        self.capability = capability
        self.hfID = hfID
        self.revisionPrefix = revisionPrefix
        self.license = license
        self.cost = cost
        self.gated = gated
        self.defaultEnabled = defaultEnabled
        self.runtime = runtime
    }
}

public enum LocalModelStack: Sendable {
    /// Semantic image/text space used for broad meaning and text-to-image search.
    public static let siglip2 = LocalModelDescriptor(
        id: "siglip2-so400m-naflex",
        capability: .imageSemantic,
        hfID: "google/siglip2-so400m-patch16-naflex",
        revisionPrefix: "cc24074",
        license: "Apache-2.0",
        cost: .medium,
        defaultEnabled: true,
        runtime: "transformers")

    /// Separate visual representation. This must never be compared directly with SigLIP vectors.
    public static let dinov3 = LocalModelDescriptor(
        id: "dinov3-vitb16-lvd1689m",
        capability: .visualSimilarity,
        hfID: "facebook/dinov3-vitb16-pretrain-lvd1689m",
        revisionPrefix: "5931719",
        license: "DINOv3 License",
        cost: .small,
        gated: true,
        defaultEnabled: true,
        runtime: "transformers")

    public static let paddleOCR = LocalModelDescriptor(
        id: "paddleocr-vl-1.6",
        capability: .documentOCR,
        hfID: "PaddlePaddle/PaddleOCR-VL-1.6",
        revisionPrefix: "cdc88f5",
        license: "Apache-2.0",
        cost: .medium,
        runtime: "paddleocr")

    /// First generative vision fallback. Small enough to be the only VLM in the balanced profile.
    public static let miniCPM = LocalModelDescriptor(
        id: "minicpm-v-4.6",
        capability: .visionFallback,
        hfID: "openbmb/MiniCPM-V-4.6",
        revisionPrefix: "8169864",
        license: "Apache-2.0",
        cost: .medium,
        runtime: "transformers")

    /// Heavy fallbacks are installable but never default-resident or called for routine files.
    public static let lfm = LocalModelDescriptor(
        id: "lfm2.5-vl-3b",
        capability: .visionHeavyFallback,
        hfID: "LiquidAI/LFM2.5-VL-3B",
        revisionPrefix: "5a414ea",
        license: "LFM1.0",
        cost: .heavy,
        runtime: "transformers-remote-code")

    /// Product-supported stack for the target Mac. Models whose own execution
    /// footprint cannot reliably remain below 11.50 GB are intentionally absent.
    public static let all: [LocalModelDescriptor] = [
        siglip2, dinov3, paddleOCR, miniCPM, lfm
    ]

    public static func descriptor(id: String) -> LocalModelDescriptor? {
        all.first { $0.id == id }
    }
}

public enum LocalModelProfile: String, Codable, Sendable, CaseIterable {
    /// Prefer throughput. Embeddings + native OCR; no generative model required.
    case fast
    /// Embeddings first, MiniCPM only for unresolved images, specialist OCR when native OCR is weak.
    case balanced
    /// Same cheap-first path, with one bounded LFM2.5-VL 3B fallback for the hard queue.
    case quality
}

public struct LocalModelRouteContext: Sendable, Equatable {
    public let kind: FileKind
    public let confidence: Double
    public let hasUsefulText: Bool
    public let nativeOCRSucceeded: Bool
    public let isDocumentLikeImage: Bool

    public init(kind: FileKind, confidence: Double, hasUsefulText: Bool,
                nativeOCRSucceeded: Bool, isDocumentLikeImage: Bool) {
        self.kind = kind
        self.confidence = confidence
        self.hasUsefulText = hasUsefulText
        self.nativeOCRSucceeded = nativeOCRSucceeded
        self.isDocumentLikeImage = isDocumentLikeImage
    }
}

/// Deterministic router. Availability is passed in explicitly so routing can be tested without models.
/// It returns the cheapest useful specialists in execution order and never silently substitutes a model.
public struct LocalModelRouter: Sendable {
    public let profile: LocalModelProfile

    public init(profile: LocalModelProfile = .fast) { self.profile = profile }

    public func route(context: LocalModelRouteContext,
                      availableModelIDs: Set<String>) -> [LocalModelDescriptor] {
        var route: [LocalModelDescriptor] = []
        func append(_ model: LocalModelDescriptor) {
            guard availableModelIDs.contains(model.id), !route.contains(where: { $0.id == model.id }) else { return }
            route.append(model)
        }

        if context.kind == .image {
            append(LocalModelStack.siglip2)
            append(LocalModelStack.dinov3)
        }

        // PaddleOCR-VL consumes decoded image bytes. PDFs are handled by the
        // bounded PDFKit/Vision OCR lane and must never be sent as raw PDF
        // containers to the image worker.
        let needsSpecialistOCR = context.kind == .image && context.isDocumentLikeImage
            && !context.nativeOCRSucceeded
        if profile != .fast, needsSpecialistOCR { append(LocalModelStack.paddleOCR) }

        // Generative models are escalation, never the baseline. Manual cleanup can tolerate uncertainty,
        // so 0.55 is intentionally loose: below it we ask a specialist rather than creating folder spam.
        let ambiguous = context.confidence < 0.55
        if profile != .fast, context.kind == .image, ambiguous {
            append(LocalModelStack.miniCPM)
        }
        if profile == .quality, ambiguous, context.kind == .image {
            // LFM2.5-VL-3B is the largest supported fallback. Larger candidates
            // were removed rather than relying on swap/offload to hide a RAM violation.
            append(LocalModelStack.lfm)
        }
        return route
    }
}

/// Keep indexing and query-time search in the same embedding space. A model
/// must not be selected for indexing and then silently replaced by a legacy
/// provider when the user searches later.
public enum LocalEmbeddingProviderSelection {
    public static func make(
        enabled: Bool,
        requestedProviderKind: String? = nil,
        specialistBridge: SpecialistModelBridge? = nil
    ) -> any EmbeddingProvider {
        if enabled, SpecialistModelBridge.isProvisioned(LocalModelStack.siglip2) {
            return SpecialistSigLIP2EmbeddingProvider(
                bridge: specialistBridge ?? SpecialistModelBridge())
        }
        if let requestedProviderKind {
            return EmbeddingProviderFactory.make(kind: requestedProviderKind)
        }
        if enabled, CoreMLMobileCLIPProvider.isAvailable {
            return CoreMLMobileCLIPProvider()
        }
        return LocalModelEmbeddingProvider()
    }
}
