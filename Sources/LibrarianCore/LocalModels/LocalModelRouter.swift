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
    /// Balanced semantic image/text space. Base NaFlex is materially smaller
    /// than So400m while preserving native screenshot/document aspect ratios.
    public static let siglip2Base = LocalModelDescriptor(
        id: "siglip2-base-naflex",
        capability: .imageSemantic,
        hfID: "google/siglip2-base-patch16-naflex",
        revisionPrefix: "b53b807",
        license: "Apache-2.0",
        cost: .small,
        defaultEnabled: true,
        runtime: "transformers")

    /// Quality semantic image/text space. This must never share stored vectors
    /// with Base because the output dimensions/space identity differ.
    public static let siglip2So400m = LocalModelDescriptor(
        id: "siglip2-so400m-naflex",
        capability: .imageSemantic,
        hfID: "google/siglip2-so400m-patch16-naflex",
        revisionPrefix: "cc24074",
        license: "Apache-2.0",
        cost: .medium,
        defaultEnabled: false,
        runtime: "transformers")

    /// Compatibility alias for older call sites/tests while the product moves
    /// to explicit Base-vs-So400m selection. New code should use semanticModel(for:).
    public static let siglip2 = siglip2So400m

    /// Optional advanced visual representation. It remains routable whenever a
    /// user explicitly provisions it, but upstream access is gated, so normal
    /// Fast/Balanced/Quality setup never depends on it. DINO vectors must never
    /// be compared directly with SigLIP vectors.
    public static let dinov3 = LocalModelDescriptor(
        id: "dinov3-vitb16-lvd1689m",
        capability: .visualSimilarity,
        hfID: "facebook/dinov3-vitb16-pretrain-lvd1689m",
        revisionPrefix: "5931719",
        license: "DINOv3 License",
        cost: .small,
        gated: true,
        defaultEnabled: false,
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

    /// Product-supported registry for the target Mac. `all` includes optional
    /// advanced specialists; consumer profiles decide which semantic encoder
    /// belongs in one run so incompatible SigLIP spaces are never mixed.
    public static let all: [LocalModelDescriptor] = [
        siglip2Base, siglip2So400m, dinov3, paddleOCR, miniCPM, lfm
    ]

    public static func descriptor(id: String) -> LocalModelDescriptor? {
        all.first { $0.id == id }
    }

    /// Fast stays zero-download. Balanced uses Base NaFlex for throughput.
    /// Quality swaps to So400m rather than stacking both semantic encoders.
    public static func semanticModel(for profile: LocalModelProfile) -> LocalModelDescriptor? {
        switch profile {
        case .fast: return nil
        case .balanced: return siglip2Base
        case .quality: return siglip2So400m
        }
    }
}

public enum LocalModelProfile: String, Codable, Sendable, CaseIterable {
    /// Built-in macOS analysis only; no downloaded semantic encoder required.
    case fast
    /// Base NaFlex first, MiniCPM only for unresolved images, native OCR on macOS.
    case balanced
    /// So400m NaFlex first, with one bounded LFM2.5-VL 3B fallback for the hard queue.
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

        if context.kind == .image, profile != .fast {
            if let semantic = LocalModelStack.semanticModel(for: profile) {
                append(semantic)
            }
            // Advanced DINOv3 is opportunistic for Balanced/Quality only. Fast
            // intentionally remains the no-download/no-Python path.
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
        profile: LocalModelProfile = .fast,
        requestedProviderKind: String? = nil,
        specialistBridge: SpecialistModelBridge? = nil
    ) -> any EmbeddingProvider {
        if enabled,
           let semantic = LocalModelStack.semanticModel(for: profile),
           SpecialistModelBridge.isProvisioned(semantic) {
            return SpecialistSigLIP2EmbeddingProvider(
                model: semantic,
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
