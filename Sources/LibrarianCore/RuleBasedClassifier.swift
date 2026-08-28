import Foundation

/// Deterministic, tool-less classifier. Produces the contract-shaped
/// Classification from extracted evidence + extracted text. No LLM in v1 —
/// this is the "cheap deterministic evidence → small classifier" stage, with
/// the same strict output schema an LLM would be held to later.
public struct RuleBasedClassifier: Sendable {

    public init() {}

    /// Multi-label classification (plan §26): kind / domain / course / purpose
    /// style labels derived only from evidence, bounded text, and optional Vision labels.
    public func classify(fileID: String, identity: FileIdentity, evidence: EvidenceExtractor.Evidence,
                         textContent: String?, visionLabels: [(String, Float)] = [],
                         screenshot: ScreenshotAssessment? = nil) -> Classification {
        var cats: [String] = []
        var reasons: [String] = []

        // Kind-level labels.
        switch identity.kind {
        case .image: cats.append("Image"); reasons.append("kind:image")
        case .audio: cats.append("Audio"); reasons.append("kind:audio")
        case .video: cats.append("Video"); reasons.append("kind:video")
        case .pdf: cats.append("Documents/PDF"); reasons.append("kind:pdf")
        case .text: cats.append("Documents/Text"); reasons.append("kind:text")
        case .office: cats.append("Documents/Office"); reasons.append("kind:office")
        case .archive: cats.append("Archives"); reasons.append("kind:archive")
        case .diskImage: cats.append("DiskImages"); reasons.append("kind:diskimage")
        case .application: cats.append("Applications"); reasons.append("kind:app")
        case .package: cats.append("Packages"); reasons.append("kind:package")
        case .symlink: cats.append("Links"); reasons.append("kind:symlink")
        case .other: cats.append("Review"); reasons.append("kind:unknown")
        }

        if evidence.isCloudPlaceholder {
            cats.append("Review/CloudPlaceholder")
            reasons.append("cloud-placeholder")
        }
        if evidence.sizeClass == "huge" {
            reasons.append("size:huge")
        }

        var confidence = 0.55 // base for kind-only classification

        // Content-aware labels from bounded text (deterministic keyword rules).
        if let text = textContent?.lowercased() {
            let courseHits = Self.courseTokens(in: text)
            for course in courseHits {
                cats.append("School/\(course)")
                reasons.append("text:\(course)")
            }
            if !courseHits.isEmpty { confidence += 0.2 }
            if text.contains("blackboard") || text.contains("canvas") {
                cats.append("School")
                reasons.append("text:lms-mention")
            }
            if text.contains("worksheet") || text.contains("assignment") || text.contains("homework") {
                cats.append("Assignment")
                reasons.append("text:assignment-word")
            }
            if text.contains("screenshot") {
                cats.append("Screenshot")
                reasons.append("text:screenshot-word")
            }
        }

        // Vision labels for images (on-device VNClassifyImageRequest).
        for (label, conf) in visionLabels.prefix(6) where conf >= 0.15 {
            let normalized = label.split(separator: ",").first.map(String.init) ?? label
            let trimmed = normalized.trimmingCharacters(in: .whitespaces).prefix(32)
            guard !trimmed.isEmpty else { continue }
            // Map common Vision labels to readable categories; keep raw label too for search.
            let cat = Self.visionCategory(for: String(trimmed))
            cats.append(cat)
            reasons.append("vision:\(trimmed.lowercased().replacingOccurrences(of: " ", with: "-"))")
            if conf >= 0.5 { confidence += 0.05 }
        }

        // Filename tokens as weak signals.
        let tokens = Set(evidence.filenameTokens)
        if tokens.contains("screenshot") {
            cats.append("Screenshot")
            reasons.append("filename:screenshot")
            confidence += 0.1
        }
        if tokens.contains(where: { $0.hasPrefix("csc") || $0.hasPrefix("mat") }) {
            cats.append("School")
            reasons.append("filename:course-like-token")
        }

        if let screenshot, screenshot.isScreenshot {
            cats.append("Screenshots")
            if screenshot.subtype != .unknown { cats.append("Screenshots/\(screenshot.subtype.rawValue)") }
            if screenshot.isUncertain { cats.append("Review") }
            reasons.append(contentsOf: screenshot.reasonCodes.map { "screenshot:\($0)" })
            confidence = max(confidence, Double(screenshot.confidence))
        }

        // Dedupe while preserving order; cap categories via the contract.
        var seen = Set<String>()
        cats = cats.filter { seen.insert($0).inserted }
        if cats.count > ClassifierContract.maxCategories {
            cats = Array(cats.prefix(ClassifierContract.maxCategories))
            reasons.append("categories-capped")
        }

        confidence = min(confidence, 0.99)
        return Classification(
            fileID: fileID,
            categories: cats,
            description: Self.describe(identity: identity, evidence: evidence),
            confidence: confidence,
            reasonCodes: Array(reasons.prefix(ClassifierContract.maxReasonCodes))
        )
    }

    static func courseTokens(in lowercasedText: String) -> [String] {
        // CSC-151 / MAT-171 style course codes.
        var found: [String] = []
        let pattern = try! NSRegularExpression(pattern: #"\b(csc|mat|bio|chm|phy|eng|his)[ -]?(\d{3})\b"#)
        let ns = lowercasedText as NSString
        for m in pattern.matches(in: lowercasedText, range: NSRange(location: 0, length: ns.length)) {
            let dept = ns.substring(with: m.range(at: 1)).uppercased()
            let num = ns.substring(with: m.range(at: 2))
            found.append("\(dept)-\(num)")
        }
        return Array(Set(found)).sorted()
    }

    static func describe(identity: FileIdentity, evidence: EvidenceExtractor.Evidence) -> String {
        let name = (identity.path as NSString).lastPathComponent
        return "\(identity.kind.rawValue) · \(evidence.sizeClass) · \(name)"
    }

    static func visionCategory(for label: String) -> String {
        let l = label.lowercased()
        if ["cat", "dog", "bird", "horse", "elephant", "bear"].contains(where: { l.contains($0) }) { return "Image/Animals/\(label)" }
        if ["car", "truck", "bus", "bicycle", "airplane", "boat"].contains(where: { l.contains($0) }) { return "Image/Vehicles/\(label)" }
        if ["beach", "mountain", "forest", "desert", "sky", "sunset"].contains(where: { l.contains($0) }) { return "Image/Scenery/\(label)" }
        if ["food", "pizza", "cake", "fruit", "vegetable"].contains(where: { l.contains($0) }) { return "Image/Food/\(label)" }
        if l.contains("screenshot") || l.contains("screen") { return "Image/Screenshots" }
        if l.contains("text") || l.contains("document") || l.contains("paper") { return "Image/Documents/\(label)" }
        return "Image/\(label)"
    }
}
