import Foundation

/// Deterministic, tool-less classifier. Produces the contract-shaped
/// Classification from extracted evidence + extracted text. No LLM in v1 —
/// this is the "cheap deterministic evidence → small classifier" stage, with
/// the same strict output schema an LLM would be held to later.
public struct RuleBasedClassifier: Sendable {

    private static let sourceCodeExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "go", "h", "hpp", "java", "js", "jsx",
        "kt", "m", "mm", "php", "py", "rb", "rs", "sh", "swift", "ts", "tsx"
    ]

    private static let projectManifestNames: Set<String> = [
        "cargo.toml", "dockerfile", "go.mod", "makefile", "package.json",
        "package.swift", "pom.xml", "pyproject.toml", "requirements.txt"
    ]

    public init() {}

    /// Multi-label classification (plan §26): kind / domain / course / purpose
    /// style labels derived only from evidence, bounded text, and optional Vision labels.
    ///
    /// Automatic categories intentionally use a bounded taxonomy. Raw Vision
    /// labels stay as evidence/reason codes instead of becoming one-off virtual
    /// folders. That keeps the organizer useful on a huge photo/screenshot
    /// library instead of creating thousands of singleton categories.
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
            if text.contains("blackboard") || text.contains("canvas") || text.contains("moodle") {
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

        // Course codes in the filename are stronger than generic filename tokens.
        let filename = (identity.path as NSString).lastPathComponent
        for course in Self.courseTokens(in: filename.lowercased()) {
            cats.append("School/\(course)")
            reasons.append("filename:\(course)")
            confidence += 0.1
        }

        // Source files and well-known project manifests get one broad project
        // bucket. We deliberately do not invent a folder from every repository,
        // framework, language, or package name.
        if Self.looksLikeCodeProject(identity: identity) {
            cats.append("Projects/Code")
            reasons.append("project:code")
            confidence += 0.15
        }

        // Vision labels for images (on-device VNClassifyImageRequest). Unknown
        // labels are evidence only; only a small curated set becomes taxonomy.
        for (label, conf) in visionLabels.prefix(6) where conf >= 0.15 {
            let normalized = label.split(separator: ",").first.map(String.init) ?? label
            let trimmed = String(normalized.trimmingCharacters(in: .whitespaces).prefix(32))
            guard !trimmed.isEmpty else { continue }
            reasons.append("vision:\(trimmed.lowercased().replacingOccurrences(of: " ", with: "-"))")
            if let category = Self.visionCategory(for: trimmed) {
                cats.append(category)
                if conf >= 0.5 { confidence += 0.05 }
            }
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
        // Common college course codes. Keeping the department prefix bounded
        // avoids treating arbitrary product/version numbers as courses.
        var found: [String] = []
        let pattern = try! NSRegularExpression(
            pattern: #"\b(art|bio|bus|chm|com|csc|eco|eng|fre|his|mat|phy|psy|soc|spa)[ -]?(\d{3,4})\b"#)
        let ns = lowercasedText as NSString
        for m in pattern.matches(in: lowercasedText, range: NSRange(location: 0, length: ns.length)) {
            let dept = ns.substring(with: m.range(at: 1)).uppercased()
            let num = ns.substring(with: m.range(at: 2))
            found.append("\(dept)-\(num)")
        }
        return Array(Set(found)).sorted()
    }

    static func looksLikeCodeProject(identity: FileIdentity) -> Bool {
        let filename = (identity.path as NSString).lastPathComponent.lowercased()
        if projectManifestNames.contains(filename) { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return sourceCodeExtensions.contains(ext)
    }

    static func describe(identity: FileIdentity, evidence: EvidenceExtractor.Evidence) -> String {
        let name = (identity.path as NSString).lastPathComponent
        return "\(identity.kind.rawValue) · \(evidence.sizeClass) · \(name)"
    }

    /// Return only curated, stable image buckets. The raw Vision label remains
    /// in reasonCodes for inspection, but it never becomes `Image/<random>`.
    static func visionCategory(for label: String) -> String? {
        let l = label.lowercased()
        if ["cat", "dog", "bird", "horse", "elephant", "bear", "animal"].contains(where: { l.contains($0) }) {
            return "Image/Animals"
        }
        if ["car", "truck", "bus", "bicycle", "airplane", "boat", "vehicle"].contains(where: { l.contains($0) }) {
            return "Image/Vehicles"
        }
        if ["beach", "mountain", "forest", "desert", "sky", "sunset", "landscape"].contains(where: { l.contains($0) }) {
            return "Image/Scenery"
        }
        if ["food", "pizza", "cake", "fruit", "vegetable", "meal"].contains(where: { l.contains($0) }) {
            return "Image/Food"
        }
        if l.contains("screenshot") || l.contains("screen") { return "Screenshots" }
        if l.contains("text") || l.contains("document") || l.contains("paper") { return "Image/Documents" }
        return nil
    }
}
