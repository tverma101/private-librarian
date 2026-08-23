import Foundation

public enum ScreenshotSubtype: String, Sendable, Codable, CaseIterable {
    case code
    case school
    case lms
    case receipt
    case error
    case conversation
    case social
    case map
    case meme
    case reference
    case unknown
}

public struct ScreenshotAssessment: Sendable, Equatable {
    public let isScreenshot: Bool
    public let subtype: ScreenshotSubtype
    public let confidence: Float
    public let reasonCodes: [String]

    public init(isScreenshot: Bool, subtype: ScreenshotSubtype, confidence: Float, reasonCodes: [String]) {
        self.isScreenshot = isScreenshot
        self.subtype = subtype
        self.confidence = confidence
        self.reasonCodes = reasonCodes
    }
}

/// Cheap deterministic first pass for screenshot organization.
/// Future OCR/MobileCLIP signals can be added without changing callers.
public struct ScreenshotIntelligence: Sendable {
    public init() {}

    public func assess(filename: String, ocrText: String?, visionLabels: [String] = []) -> ScreenshotAssessment {
        let name = filename.lowercased()
        let text = (ocrText ?? "").lowercased()
        let labels = visionLabels.map { $0.lowercased() }

        let screenshotHints = ["screenshot", "screen shot", "screen-shot"]
        let looksLikeScreenshot = screenshotHints.contains(where: { name.contains($0) })
        guard looksLikeScreenshot else {
            return ScreenshotAssessment(isScreenshot: false, subtype: .unknown, confidence: 0, reasonCodes: ["not-screenshot-name"])
        }

        struct Rule {
            let subtype: ScreenshotSubtype
            let tokens: [String]
            let reason: String
        }

        let rules: [Rule] = [
            Rule(subtype: .lms, tokens: ["blackboard", "canvas", "moodle", "assignment", "course content"], reason: "ocr:lms"),
            Rule(subtype: .code, tokens: ["public static void", "class ", "import ", "traceback", "exception", "github", "visual studio code", "vscode"], reason: "ocr:code"),
            Rule(subtype: .school, tokens: ["quiz", "chapter", "homework", "worksheet", "precalculus", "java programming", "wake tech"], reason: "ocr:school"),
            Rule(subtype: .receipt, tokens: ["subtotal", "total", "order #", "order number", "receipt", "tax", "shipping"], reason: "ocr:receipt"),
            Rule(subtype: .error, tokens: ["error", "failed", "warning", "crash", "cannot", "permission denied"], reason: "ocr:error"),
            Rule(subtype: .conversation, tokens: ["message", "sent", "delivered", "typing…", "typing..."], reason: "ocr:conversation"),
            Rule(subtype: .map, tokens: ["directions", "miles", "min", "route", "arrive", "maps"], reason: "ocr:map"),
            Rule(subtype: .social, tokens: ["followers", "following", "repost", "retweet", "likes", "comments"], reason: "ocr:social"),
            Rule(subtype: .meme, tokens: ["meme"], reason: "ocr:meme")
        ]

        var best: (ScreenshotSubtype, Int, String)?
        for rule in rules {
            let score = rule.tokens.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
            if score > 0 && (best == nil || score > best!.1) {
                best = (rule.subtype, score, rule.reason)
            }
        }

        if let best {
            let confidence = min(0.95, 0.58 + Float(best.1) * 0.09)
            return ScreenshotAssessment(isScreenshot: true, subtype: best.0, confidence: confidence, reasonCodes: ["filename:screenshot", best.2])
        }

        if labels.contains(where: { $0.contains("map") || $0.contains("navigation") }) {
            return ScreenshotAssessment(isScreenshot: true, subtype: .map, confidence: 0.62, reasonCodes: ["filename:screenshot", "vision:map"])
        }

        return ScreenshotAssessment(isScreenshot: true, subtype: .reference, confidence: 0.45, reasonCodes: ["filename:screenshot", "fallback:reference"])
    }
}
