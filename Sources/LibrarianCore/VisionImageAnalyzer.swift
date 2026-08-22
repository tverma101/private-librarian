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
/// Both are bounded reads through SourceBroker (O_RDONLY|O_NOFOLLOW) so
/// symlinks are never followed. Failures return nil — never crash indexing.
public struct VisionImageAnalyzer: Sendable {

    public static let revision = "vision-1.0"
    /// Max bytes to read for Vision. 8 MiB default covers most photos;
    /// larger images are truncated — Vision still classifies the header window.
    public static let maxVisionBytes: Int64 = 8 * 1024 * 1024

    public struct Result: Sendable {
        /// Top labels sorted by confidence desc, filtered to confidence >= threshold.
        public let classifications: [(label: String, confidence: Float)]
        /// Opaque feature-print bytes (VNFeaturePrintObservation.data) for similarity.
        public let featurePrint: Data?
        /// VNFeaturePrint revision string for invalidation.
        public let featureRevision: String
    }

    public init() {}

    /// Analyze an image file through the read-only broker.
    /// Returns nil if the file cannot be read or Vision produces no result.
    public func analyze(path: String, broker: SourceBroker) -> Result? {
        guard let data = try? broker.boundedRead(path, limit: Self.maxVisionBytes), !data.isEmpty else {
            return nil
        }
        return analyze(data: data)
    }

    /// Analyze raw image data (for tests / in-memory callers).
    public func analyze(data: Data) -> Result? {
        guard !data.isEmpty else { return nil }
        let classifications = Self.classify(data: data)
        let fp = Self.featurePrint(data: data)
        if classifications.isEmpty && fp == nil { return nil }
        return Result(classifications: classifications,
                      featurePrint: fp?.data,
                      featureRevision: fp?.revision ?? Self.revision)
    }

    // MARK: - Vision requests

    static func classify(data: Data, topK: Int = 8, threshold: Float = 0.08) -> [(String, Float)] {
        let handler = VNImageRequestHandler(data: data, options: [:])
        let req = VNClassifyImageRequest()
        do {
            try handler.perform([req])
            guard let results = req.results as? [VNClassificationObservation] else { return [] }
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
        let handler = VNImageRequestHandler(data: data, options: [:])
        let req = VNGenerateImageFeaturePrintRequest()
        // Use default revision; pin if needed for stable invalidation.
        do {
            try handler.perform([req])
            guard let obs = req.results?.first as? VNFeaturePrintObservation else { return nil }
            // VNFeaturePrintObservation.data is the compact embedding.
            // Compute revision from the request's revision if available.
            let rev = "\(VNGenerateImageFeaturePrintRequestRevision1)"
            if let d = (obs as AnyObject).value(forKey: "data") as? Data, !d.isEmpty {
                return FPBox(data: d, revision: rev)
            }
            // Fallback: encode via NSKeyedArchiver for persistence & distance via Vision API.
            if let archived = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true), !archived.isEmpty {
                return FPBox(data: archived, revision: rev)
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
