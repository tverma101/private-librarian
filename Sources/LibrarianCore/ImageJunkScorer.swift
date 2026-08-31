import Foundation
import CoreGraphics
import ImageIO

/// Cheap, deterministic evidence for obviously disposable images. This never
/// deletes a source file: it only contributes the virtual `Image/Junk` label
/// so a cleanup run can surface likely garbage for human review.
public struct ImageJunkAssessment: Sendable, Equatable {
    public let isLikelyJunk: Bool
    public let score: Double
    public let reasons: [String]

    public init(isLikelyJunk: Bool, score: Double, reasons: [String]) {
        self.isLikelyJunk = isLikelyJunk
        self.score = max(0, min(1, score))
        self.reasons = reasons
    }
}

public enum ImageJunkScorer {
    public static let revision = "image-junk-1.0"
    public static let threshold = 0.85

    /// High-precision junk assessment. Useful text or a confident useful Vision
    /// concept is a hard veto; ambiguous images stay out of Junk rather than
    /// risking a false-positive cleanup suggestion.
    public static func assess(
        data: Data,
        ocrText: String?,
        visionLabels: [(String, Float)] = [],
        isScreenshot: Bool = false
    ) -> ImageJunkAssessment {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else {
            return ImageJunkAssessment(isLikelyJunk: false, score: 0, reasons: ["image-unreadable"])
        }

        if hasMeaningfulText(ocrText) {
            return ImageJunkAssessment(isLikelyJunk: false, score: 0, reasons: ["useful-text"])
        }
        if hasProtectedVisionEvidence(visionLabels) {
            return ImageJunkAssessment(isLikelyJunk: false, score: 0, reasons: ["useful-visual-content"])
        }

        let maxSide = max(width, height)
        let minSide = min(width, height)
        let pixelCount = Int64(width) * Int64(height)
        let aspect = Double(maxSide) / Double(max(1, minSide))
        let stats = informationStats(source: source)

        var score = 0.0
        var reasons: [String] = []

        if maxSide <= 256 {
            score += 0.35
            reasons.append("tiny-dimensions")
        }
        if pixelCount <= 65_536 {
            score += 0.25
            reasons.append("low-pixel-count")
        }
        if data.count <= 12 * 1024 {
            score += 0.10
            reasons.append("tiny-file")
        }
        if aspect >= 10 {
            score += 0.20
            reasons.append("extreme-aspect-ratio")
        }

        if let stats {
            // A tiny thumbnail can alias a real icon, gradient or high-frequency
            // graphic into something that looks blank. Thumbnail sparsity is
            // therefore strong junk evidence only when the ORIGINAL image is
            // objectively disposable-looking too (very small or extreme shape).
            let objectivelyDisposableShape =
                maxSide <= 128 || pixelCount <= 16_384 || aspect >= 10
            if stats.range <= 8 || stats.variance <= 4 {
                score += objectivelyDisposableShape ? 0.65 : 0.10
                reasons.append("near-blank")
            } else if stats.occupiedBins <= 3 || stats.variance <= 18 {
                score += objectivelyDisposableShape ? 0.20 : 0.05
                reasons.append("very-low-information")
            }
        }

        // A screenshot is often intentionally saved evidence. It may still be
        // junk when it is objectively tiny/blank, but require stronger evidence.
        if isScreenshot && !(reasons.contains("near-blank") && maxSide <= 512) {
            score -= 0.15
            reasons.append("screenshot-protection")
        }

        let normalized = max(0, min(1, score))
        return ImageJunkAssessment(
            isLikelyJunk: normalized >= threshold,
            score: normalized,
            reasons: Array(reasons.prefix(8)))
    }

    private static func hasMeaningfulText(_ text: String?) -> Bool {
        guard let text else { return false }
        let count = text.unicodeScalars.reduce(into: 0) { total, scalar in
            if CharacterSet.alphanumerics.contains(scalar) { total += 1 }
        }
        return count >= 24
    }

    private static func hasProtectedVisionEvidence(_ labels: [(String, Float)]) -> Bool {
        let protectedTerms = [
            "person", "face", "portrait", "people", "child", "dog", "cat", "animal",
            "bird", "food", "meal", "car", "vehicle", "landscape", "beach", "mountain",
            "flower", "document", "paper", "book", "map", "diagram", "chart", "receipt",
            "screen", "computer", "laptop", "phone", "building", "room", "furniture"
        ]
        return labels.contains { label, confidence in
            guard confidence >= 0.30 else { return false }
            let lower = label.lowercased()
            return protectedTerms.contains { lower.contains($0) }
        }
    }

    private struct InformationStats {
        let range: Int
        let variance: Double
        let occupiedBins: Int
    }

    private static func informationStats(source: CGImageSource) -> InformationStats? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered, !pixels.isEmpty else { return nil }

        var minimum = 255
        var maximum = 0
        var sum = 0.0
        var sumSquares = 0.0
        var bins = Set<Int>()
        bins.reserveCapacity(16)
        for pixel in pixels {
            let value = Int(pixel)
            minimum = min(minimum, value)
            maximum = max(maximum, value)
            sum += Double(value)
            sumSquares += Double(value * value)
            bins.insert(value / 16)
        }
        let count = Double(pixels.count)
        let mean = sum / count
        let variance = max(0, sumSquares / count - mean * mean)
        return InformationStats(
            range: maximum - minimum,
            variance: variance,
            occupiedBins: bins.count)
    }
}
