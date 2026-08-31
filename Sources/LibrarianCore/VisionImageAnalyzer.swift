import Foundation
import Vision
#if canImport(AppKit)
import AppKit
#endif

/// On-device image analysis using Apple Vision. Zero download, no network,
/// no extra entitlements. Runs entirely offline via the Vision framework.
///
/// Two signals:
///  1. VNClassifyImageRequest — ~1k ImageNet-style labels (e.g. "cat", "beach")
///  2. VNGenerateImageFeaturePrintRequest — compact embedding for visual dedup / similarity
///
/// The broker supplies complete image-container bytes using
/// O_RDONLY|O_NOFOLLOW and an explicit fail-closed cap. Failures return nil —
/// never crash indexing.
public struct VisionImageAnalyzer: Sendable {

    public static let revision = "vision-1.2-classify-feature"
    /// Maximum compressed image-container size accepted by the decoder path.
    /// This is deliberately above the old 8 MiB evidence-read cap; containers
    /// are either passed whole or rejected, never prefix-decoded.
    public static let maxImageContainerBytes: Int64 = 256 * 1024 * 1024
    @available(*, deprecated, message: "Use maxImageContainerBytes; decoder inputs are complete containers")
    public static let maxVisionBytes: Int64 = maxImageContainerBytes

    public struct Result: Sendable {
        /// Top labels sorted by confidence desc, filtered to confidence >= threshold.
        public let classifications: [(label: String, confidence: Float)]
        /// Opaque feature-print bytes (VNFeaturePrintObservation.data) for similarity.
        public let featurePrint: Data?
        /// VNFeaturePrint revision string for invalidation.
        public let featureRevision: String
        /// Bounded OCR text from the same broker-supplied image bytes.
        public let recognizedText: String?
    }

    public init() {}

    /// Compatibility wrapper for existing source-path callers. The path is
    /// consumed only by SourceBroker; Vision receives broker-owned bytes.
    public func analyze(path: String, broker: SourceBroker) -> Result? {
        guard let data = try? broker.completeSnapshot(path, maxBytes: Self.maxImageContainerBytes), !data.isEmpty else {
            return nil
        }
        return analyze(data: data)
    }

    /// Analyze raw image data (for tests / in-memory callers).
    /// Batched: single VNImageRequestHandler decode for both classify + feature-print (halves ANE work).
    public func analyze(data: Data, includeOCR: Bool = true) -> Result? {
        guard !data.isEmpty, data.count <= Self.maxImageContainerBytes else { return nil }
        let handler = VNImageRequestHandler(data: data, options: [:])
        let classifyReq = VNClassifyImageRequest()
        let fpReq = VNGenerateImageFeaturePrintRequest()
        let textReq: VNRecognizeTextRequest? = {
            guard includeOCR else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            return request
        }()
        var requests: [VNRequest] = [classifyReq, fpReq]
        if let textReq { requests.append(textReq) }
        do {
            try handler.perform(requests)
        } catch {
            return nil
        }
        let classifications: [(String, Float)] = {
            guard let results = classifyReq.results else { return [] }
            return results.filter { $0.confidence >= 0.08 }.prefix(8).map { ($0.identifier, $0.confidence) }
        }()
        let fp: FPBox? = {
            guard let obs = fpReq.results?.first as? VNFeaturePrintObservation else { return nil }
            let rev = "\(VNGenerateImageFeaturePrintRequestRevision1)"
            // Primary: stable archived form (always decodable by Vision's computeDistance).
            // KVC `data` is best-effort legacy — stored blobs are normalized to archived form
            // so distance() never has to compare mixed formats (raw vs archived would silently fail).
            if let archived = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true), !archived.isEmpty {
                return FPBox(data: archived, revision: rev)
            }
            if let d = (obs as AnyObject).value(forKey: "data") as? Data, !d.isEmpty {
                // Fallback only — still wrap via archiver failed above (should not happen).
                return FPBox(data: d, revision: rev)
            }
            return nil
        }()
        let recognizedText = (textReq?.results?.compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ") ?? "").prefix(20_000)
        let text = recognizedText.isEmpty ? nil : String(recognizedText)
        if classifications.isEmpty && fp == nil && text == nil { return nil }
        return Result(classifications: classifications,
                      featurePrint: fp?.data,
                      featureRevision: fp?.revision ?? Self.revision,
                      recognizedText: text)
    }

    // MARK: - Vision requests (single-request helpers for SearchService.visualSearch + tests)

    static func classify(data: Data, topK: Int = 8, threshold: Float = 0.08) -> [(String, Float)] {
        guard !data.isEmpty, data.count <= maxImageContainerBytes, topK > 0,
              threshold.isFinite else { return [] }
        let handler = VNImageRequestHandler(data: data, options: [:])
        let req = VNClassifyImageRequest()
        do {
            try handler.perform([req])
            guard let results = req.results else { return [] }
            return results
                .filter { $0.confidence >= threshold }
                .prefix(topK)
                .map { ($0.identifier, $0.confidence) }
        } catch {
            return []
        }
    }

    struct FPBox { let data: Data; let revision: String }

    static func featurePrint(data: Data) -> FPBox? {
        guard !data.isEmpty, data.count <= maxImageContainerBytes else { return nil }
        let handler = VNImageRequestHandler(data: data, options: [:])
        let req = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([req])
            guard let obs = req.results?.first as? VNFeaturePrintObservation else { return nil }
            let rev = "\(VNGenerateImageFeaturePrintRequestRevision1)"
            if let archived = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true), !archived.isEmpty {
                return FPBox(data: archived, revision: rev)
            }
            if let d = (obs as AnyObject).value(forKey: "data") as? Data, !d.isEmpty {
                return FPBox(data: d, revision: rev)
            }
            return nil
        } catch {
            return nil
        }
    }

    /// Cosine-like distance between two feature-print blobs via Vision's own metric.
    /// Returns nil if either blob cannot be decoded.
    public static func distance(_ a: Data, _ b: Data) -> Float? {
        guard let obsA = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: a),
              let obsB = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: b) else {
            // If blobs are raw feature bytes (not archived observations), fall back to
            // normalized byte-level cosine.
            return cosineDistance(a, b)
        }
        var dist: Float = 0
        do {
            try obsA.computeDistance(&dist, to: obsB)
            return dist // 0 = identical, larger = more different (Vision docs: 0..~1.5)
        } catch {
            return nil
        }
    }

    static func cosineDistance(_ a: Data, _ b: Data) -> Float? {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return nil }
        let n = a.count
        var dot: Double = 0, magA: Double = 0, magB: Double = 0
        a.withUnsafeBytes { ap in
            b.withUnsafeBytes { bp in
                guard let pa = ap.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let pb = bp.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for i in 0..<n {
                    let fa = Double(pa[i]) / 255.0
                    let fb = Double(pb[i]) / 255.0
                    dot += fa * fb
                    magA += fa * fa
                    magB += fb * fb
                }
            }
        }
        let denom = sqrt(magA) * sqrt(magB)
        guard denom > 1e-9 else { return nil }
        let cos = dot / denom
        return Float(1.0 - cos) // distance in [0,2]
    }
}
