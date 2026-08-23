import Foundation
import ImageIO

public enum ScreenshotSubtype: String, Sendable, Codable, CaseIterable {
    case code, school, lms, receipt, error, conversation, social, map, meme, reference, unknown
}

public struct ScreenshotImageMetadata: Sendable, Equatable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let properties: [String]
    public init(pixelWidth: Int, pixelHeight: Int, properties: [String] = []) {
        self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight; self.properties = properties
    }
}

public struct ScreenshotAssessment: Sendable, Equatable, Codable {
    public let isScreenshot: Bool
    public let subtype: ScreenshotSubtype
    public let confidence: Float
    public let reasonCodes: [String]
    public init(isScreenshot: Bool, subtype: ScreenshotSubtype, confidence: Float, reasonCodes: [String]) {
        self.isScreenshot = isScreenshot; self.subtype = subtype
        self.confidence = max(0, min(1, confidence)); self.reasonCodes = Array(reasonCodes.prefix(16))
    }
    public var isUncertain: Bool { isScreenshot && confidence < 0.80 }
}

/// Deterministic screenshot organization. Filename evidence is deliberately
/// weak: a filename alone can never classify an image as a screenshot.
public struct ScreenshotIntelligence: Sendable {
    public init() {}

    /// Reads only image bytes supplied by the broker; never opens a source path.
    public static func metadata(from data: Data) -> ScreenshotImageMetadata? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let names = props.keys.compactMap { key -> String? in
            let value = props[key]
            let text = "\(key) \(String(describing: value))".lowercased()
            return ["screen", "display", "screenshot", "iphone", "ipad", "simulator"].contains(where: text.contains) ? text : nil
        }
        return ScreenshotImageMetadata(pixelWidth: width, pixelHeight: height, properties: names)
    }

    public func assess(filename: String, metadata: ScreenshotImageMetadata? = nil,
                       ocrText: String? = nil, visionLabels: [String] = []) -> ScreenshotAssessment {
        let name = filename.lowercased(), text = (ocrText ?? "").lowercased()
        let labels = visionLabels.map { $0.lowercased() }
        var reasons: [String] = []; var score: Float = 0
        if name.contains("screenshot") || name.contains("screen shot") || name.contains("screen-shot") {
            score += 0.20; reasons.append("filename:screenshot")
        }
        if let metadata {
            let ratio = Float(max(metadata.pixelWidth, metadata.pixelHeight)) / Float(min(metadata.pixelWidth, metadata.pixelHeight))
            if Self.screenRatio(ratio) && min(metadata.pixelWidth, metadata.pixelHeight) >= 500 {
                score += 0.35; reasons.append("dimensions:screen-ratio")
            }
            if metadata.properties.contains(where: { $0.contains("screen") || $0.contains("display") || $0.contains("iphone") || $0.contains("ipad") }) {
                score += 0.25; reasons.append("metadata:display")
            }
        }
        let uiTokens = ["settings", "search", "share", "menu", "home", "back", "notifications", "browser", "tab", "http", "www"]
        let uiHits = uiTokens.filter(text.contains)
        if !uiHits.isEmpty { score += min(0.30, 0.10 + Float(uiHits.count) * 0.04); reasons.append("content:ui-text") }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 0.10; reasons.append("content:ocr") }
        if labels.contains(where: { $0.contains("screen") || $0.contains("computer") || $0.contains("monitor") }) {
            score += 0.20; reasons.append("vision:screen-like")
        }
        guard score >= 0.40 else {
            return ScreenshotAssessment(isScreenshot: false, subtype: .unknown, confidence: score,
                                         reasonCodes: reasons.isEmpty ? ["insufficient-screenshot-evidence"] : reasons)
        }
        let subtype = Self.subtype(text: text, labels: labels)
        if subtype == .reference { reasons.append("fallback:reference") }
        let confidence = min(0.99, 0.35 + score * 0.60 + (subtype == .reference ? 0 : 0.15))
        if confidence < 0.80 { reasons.append("uncertain:review") }
        return ScreenshotAssessment(isScreenshot: true, subtype: subtype, confidence: confidence, reasonCodes: reasons)
    }

    /// Compatibility overload for callers that only have text/labels.
    public func assess(filename: String, ocrText: String?, visionLabels: [String] = []) -> ScreenshotAssessment {
        assess(filename: filename, metadata: nil, ocrText: ocrText, visionLabels: visionLabels)
    }

    private static func screenRatio(_ ratio: Float) -> Bool {
        [1.333, 1.5, 1.6, 1.667, 1.778, 1.8, 2.0, 2.167].contains { abs(ratio - $0) < 0.035 }
    }

    private static func subtype(text: String, labels: [String]) -> ScreenshotSubtype {
        let rules: [(ScreenshotSubtype, [String])] = [
            (.lms, ["blackboard", "canvas", "moodle", "course content", "discussion board"]),
            (.code, ["public static void", "import ", "class ", "traceback", "exception", "github", "vscode", "terminal"]),
            (.school, ["quiz", "chapter", "homework", "worksheet", "precalculus", "java programming", "wake tech"]),
            (.receipt, ["subtotal", "total", "order #", "order number", "receipt", "tax", "shipping", "tracking"]),
            (.error, ["error", "failed", "warning", "crash", "cannot", "permission denied", "stack trace"]),
            (.conversation, ["message", "sent", "delivered", "typing", "reply", "direct message"]),
            (.social, ["followers", "following", "repost", "retweet", "likes", "comments", "share"]),
            (.map, ["directions", "miles", "route", "arrive", "maps", "navigation"]),
            (.meme, ["meme", "when you", "top text", "bottom text"])
        ]
        for (subtype, tokens) in rules where tokens.contains(where: text.contains) { return subtype }
        if labels.contains(where: { $0.contains("map") || $0.contains("navigation") }) { return .map }
        return .reference
    }
}
