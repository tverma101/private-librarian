#!/usr/bin/env python3
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"expected exactly one match in {path}, found {count}: {old[:140]!r}")
    p.write_text(text.replace(old, new, 1))


INDEXER = "Sources/LibrarianCore/Indexer.swift"
SMART = "Sources/LibrarianCore/SmartOrganization.swift"
JUNK = "Sources/LibrarianCore/ImageJunkScorer.swift"

replace_once(
    JUNK,
    '''public enum ImageJunkScorer {
    public static let threshold = 0.85
''',
    '''public enum ImageJunkScorer {
    public static let revision = "image-junk-1.0"
    public static let threshold = 0.85
'''
)

replace_once(
    INDEXER,
    '''    private let processingVersion: String
    /// Swappable ASR provider — defaults to Disabled (no transcription until benchmarked).
''',
    '''    private let processingVersion: String

    /// Image-junk heuristics are image-only derived state. Keep their generation
    /// separate so an upgrade rechecks images without forcing a giant code tree
    /// through extraction/model work again.
    private func requiredProcessingVersion(for kind: FileKind) -> String {
        kind == .image
            ? processingVersion + "|image-junk:\\(ImageJunkScorer.revision)"
            : processingVersion
    }

    /// Swappable ASR provider — defaults to Disabled (no transcription until benchmarked).
'''
)

replace_once(
    INDEXER,
    '''            try catalog.txRun(
                "UPDATE files SET last_extractor=? WHERE id=?",
                binds: [.text(processingVersion), .text(fileID)])
''',
    '''            try catalog.txRun(
                "UPDATE files SET last_extractor=? WHERE id=?",
                binds: [.text(requiredProcessingVersion(for: current.kind)), .text(fileID)])
'''
)

replace_once(
    INDEXER,
    '''        guard let ident = try? broker.identity(at: path) else { return false }

        // Critical efficiency gate: this must happen before upsert, extraction,
''',
    '''        guard let ident = try? broker.identity(at: path) else { return false }
        let generationVersion = requiredProcessingVersion(for: ident.kind)

        // Critical efficiency gate: this must happen before upsert, extraction,
'''
)

replace_once(
    INDEXER,
    '''                                            current: ident,
                                            requiredExtractorVersion: processingVersion) {
''',
    '''                                            current: ident,
                                            requiredExtractorVersion: generationVersion) {
'''
)

replace_once(
    INDEXER,
    '''            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "indexed")
            // A path that is no longer a decodable regular file cannot stand
''',
    '''            try catalog.setExtractorVersion(fileID: id, version: generationVersion)
            try catalog.setStatus(fileID: id, status: "indexed")
            // A path that is no longer a decodable regular file cannot stand
'''
)

replace_once(
    INDEXER,
    '''            try catalog.setExtractorVersion(fileID: id, version: processingVersion)
            try catalog.setStatus(fileID: id, status: "cloud-placeholder")
            // Placeholder bytes are not present; any earlier transcript does
''',
    '''            try catalog.setExtractorVersion(fileID: id, version: generationVersion)
            try catalog.setStatus(fileID: id, status: "cloud-placeholder")
            // Placeholder bytes are not present; any earlier transcript does
'''
)

replace_once(
    INDEXER,
    '''        var visionLabels: [(String, Float)] = []
        var screenshotAssessment: ScreenshotAssessment?
        var stagedFeaturePrint: (Data, String)? = nil
''',
    '''        var visionLabels: [(String, Float)] = []
        var screenshotAssessment: ScreenshotAssessment?
        var imageJunkAssessment: ImageJunkAssessment?
        var stagedFeaturePrint: (Data, String)? = nil
'''
)

replace_once(
    INDEXER,
    '''            screenshotAssessment = ScreenshotIntelligence().assess(
                filename: (ident.path as NSString).lastPathComponent,
                metadata: metadata,
                ocrText: textContent,
                visionLabels: visionLabels.map { $0.0 })
        }

        // Optional specialist OCR is an escalation only. Native text/Vision OCR wins when
''',
    '''            screenshotAssessment = ScreenshotIntelligence().assess(
                filename: (ident.path as NSString).lastPathComponent,
                metadata: metadata,
                ocrText: textContent,
                visionLabels: visionLabels.map { $0.0 })
            imageJunkAssessment = ImageJunkScorer.assess(
                data: bytes,
                ocrText: textContent,
                visionLabels: visionLabels,
                isScreenshot: screenshotAssessment?.isScreenshot == true)
        }

        // Optional specialist OCR is an escalation only. Native text/Vision OCR wins when
'''
)

replace_once(
    INDEXER,
    '''        var validatedClass: Classification? = {
            guard let data = try? classification.jsonData() else { return nil }
            return ClassifierContract.validate(data)
        }()
        let baseCategories = validatedClass?.categories
''',
    '''        var validatedClass: Classification? = {
            guard let data = try? classification.jsonData() else { return nil }
            return ClassifierContract.validate(data)
        }()
        if let junk = imageJunkAssessment, junk.isLikelyJunk,
           let base = validatedClass,
           !base.categories.contains("Image/Junk") {
            var categories = base.categories
            if categories.count < ClassifierContract.maxCategories {
                categories.append("Image/Junk")
            }
            let junkReasons = junk.reasons.map { "junk:\\($0)" }
            let trial = Classification(
                fileID: base.fileID,
                categories: categories,
                description: base.description,
                confidence: max(base.confidence, junk.score),
                reasonCodes: Array((base.reasonCodes + junkReasons)
                    .prefix(ClassifierContract.maxReasonCodes)))
            if let data = try? trial.jsonData(),
               let validated = ClassifierContract.validate(data) {
                validatedClass = validated
            }
        }
        let baseCategories = validatedClass?.categories
'''
)

replace_once(
    INDEXER,
    '''                try catalog.txRun("UPDATE files SET last_extractor=? WHERE id=?", binds: [.text(processingVersion), .text(id)])
''',
    '''                try catalog.txRun("UPDATE files SET last_extractor=? WHERE id=?", binds: [.text(generationVersion), .text(id)])
'''
)

replace_once(
    SMART,
    '''            if group.id == "composite:installers-archives" { return "downloads" }
            if group.id == "composite:media" { return "media" }
''',
    '''            if group.id == "composite:installers-archives" { return "downloads" }
            if group.id == "composite:media" { return "media" }
            if group.id == "category:Image/Junk" { return "junk" }
'''
)

replace_once(
    SMART,
    '''        case "semantic": preferred = 5
        case "downloads", "media": preferred = 1
''',
    '''        case "semantic": preferred = 5
        case "downloads", "media", "junk": preferred = 1
'''
)

replace_once(
    SMART,
    '''        if path == "Assignment" {
            return ("Assignments", "School & work", 100)
        }
        if path == "Documents/PDF" { return ("PDFs", "Documents", 90) }
''',
    '''        if path == "Assignment" {
            return ("Assignments", "School & work", 100)
        }
        if path == "Image/Junk" { return ("Likely image junk", "Review before deleting", 108) }
        if path == "Documents/PDF" { return ("PDFs", "Documents", 90) }
'''
)

print("image junk integration patch applied")
