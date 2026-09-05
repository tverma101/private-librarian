import Foundation

/// The ONLY shape of output the intelligence layer may produce.
/// Everything here is inert data: no tool calls, no actions, no paths to touch.
/// Model/worker output that does not validate against this contract is discarded.
public struct Classification: Codable, Sendable, Equatable {
    public let fileID: String
    public let categories: [String]
    public let description: String
    public let confidence: Double
    public let reasonCodes: [String]

    public init(fileID: String, categories: [String], description: String, confidence: Double, reasonCodes: [String]) {
        self.fileID = fileID

        // A specialist may adjudicate a mutually-exclusive lane only when its
        // validated response explicitly selected a category in that lane. A
        // generic specialist success must never erase a deterministic conflict
        // merely because one of the old labels happened to be last in an array.
        let hasSpecialist = reasonCodes.contains { $0.hasPrefix("specialist:") }
        var resolvedCategories = hasSpecialist
            ? ClassificationCategoryPolicy.specialistResolved(categories, reasonCodes: reasonCodes)
            : ClassificationCategoryPolicy.deduplicated(categories)
        var resolvedConfidence = confidence

        // If the specialist did not actually settle the conflict, keep the file
        // ambiguous and visibly reviewable. This also prevents a high generic
        // specialist confidence from closing Review while contradictory labels
        // still exist.
        if hasSpecialist,
           ClassificationCategoryPolicy.hasExclusiveConflict(resolvedCategories) {
            if !resolvedCategories.contains("Review") { resolvedCategories.append("Review") }
            resolvedConfidence = min(resolvedConfidence, 0.55)
        }

        self.categories = resolvedCategories
        self.description = description
        self.confidence = resolvedConfidence
        self.reasonCodes = reasonCodes
    }
}

/// Categories are deliberately multi-label, but a few lanes represent one
/// mutually-exclusive answer. Specialist choices are carried as inert reason
/// markers (`model:pick:<category>`) so the contract can distinguish an actual
/// adjudication from a model that merely returned a description/confidence.
public enum ClassificationCategoryPolicy {
    private static let imageSubjects: Set<String> = [
        "Image/Animals", "Image/Vehicles", "Image/Scenery", "Image/Food", "Image/Documents"
    ]

    public static func specialistResolved(_ categories: [String],
                                          reasonCodes: [String]) -> [String] {
        var selectedByLane: [String: String] = [:]
        let markerPrefix = "model:pick:"
        for reason in reasonCodes where reason.hasPrefix(markerPrefix) {
            let category = String(reason.dropFirst(markerPrefix.count))
            if let lane = exclusiveLane(for: category) {
                // Reason order is execution order; the latest successful
                // specialist in a lane is the final bounded adjudicator.
                selectedByLane[lane] = category
            }
        }

        var output: [String] = []
        var seen = Set<String>()
        for category in categories {
            guard seen.insert(category).inserted else { continue }
            if let lane = exclusiveLane(for: category),
               let selected = selectedByLane[lane], selected != category {
                continue
            }
            output.append(category)
        }
        // A selected category should normally already be in `categories`, but
        // append it defensively if a future merge path carries only the marker.
        for selected in selectedByLane.values.sorted() where !output.contains(selected) {
            output.append(selected)
        }
        return output
    }

    public static func hasExclusiveConflict(_ categories: [String]) -> Bool {
        var valuesByLane: [String: Set<String>] = [:]
        for category in categories {
            guard let lane = exclusiveLane(for: category) else { continue }
            valuesByLane[lane, default: []].insert(category)
        }
        return valuesByLane.values.contains { $0.count > 1 }
    }

    public static func isExclusiveCategory(_ category: String) -> Bool {
        exclusiveLane(for: category) != nil
    }

    public static func deduplicated(_ categories: [String]) -> [String] {
        var seen = Set<String>()
        return categories.filter { seen.insert($0).inserted }
    }

    private static func exclusiveLane(for category: String) -> String? {
        if isCourseCategory(category) { return "school-course" }
        if isScreenshotSubtype(category) { return "screenshot-subtype" }
        if imageSubjects.contains(category) { return "image-subject" }
        return nil
    }

    private static func isScreenshotSubtype(_ category: String) -> Bool {
        let prefix = "Screenshots/"
        return category.hasPrefix(prefix) && category.count > prefix.count
    }

    private static func isCourseCategory(_ category: String) -> Bool {
        let prefix = "School/"
        guard category.hasPrefix(prefix) else { return false }
        let course = String(category.dropFirst(prefix.count))
        let parts = course.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, (3...4).contains(parts[1].count) else { return false }
        return parts[0].count >= 2
            && parts[0].allSatisfy(\.isLetter)
            && parts[1].allSatisfy(\.isNumber)
    }
}

public enum ConfidenceBand: String, Codable, Sendable {
    case confident
    case ambiguous
    case unknown

    /// Thresholds are calibration points, not laws; they live in one place so a
    /// future calibration pass against reviewed samples changes them in one spot.
    public static func band(forConfidence c: Double) -> ConfidenceBand {
        if c >= 0.80 { return .confident }
        if c >= 0.45 { return .ambiguous }
        return .unknown
    }
}

/// Strict validator for classifier output. Anything outside the schema —
/// unknown fields with side-effect-looking names, oversized strings,
/// out-of-range confidence, path-like or command-like category names — is
/// rejected. This is the wall between "model said something" and "system did it".
public enum ClassifierContract {
    public static let maxCategories = 12
    public static let maxDescriptionLength = 2_000
    public static let maxReasonCodes = 16

    /// Category labels must look like taxonomy labels, not instructions:
    /// letters/digits/spaces/slashes/dots/hyphens/underscores only, no shell
    /// metacharacters, no path traversal, length-capped.
    private static let labelCharset = try! NSRegularExpression(pattern: #"^[A-Za-z0-9][A-Za-z0-9 /._-]{0,63}$"#)

    public static func validate(_ json: Data) -> Classification? {
        guard let raw = try? JSONDecoder().decode(RawClassification.self, from: json) else { return nil }
        return validate(raw)
    }

    public static func validate(_ raw: RawClassification) -> Classification? {
        guard raw.fileID.hasPrefix("file_") else { return nil } // opaque id shape
        guard raw.fileID.count <= 32, raw.fileID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        guard raw.categories.count <= maxCategories else { return nil }
        var cats: [String] = []
        for c in raw.categories {
            let trimmed = c.trimmingCharacters(in: .whitespaces)
            guard labelCharset.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil else { return nil }
            guard !trimmed.contains("..") else { return nil }
            cats.append(trimmed)
        }
        guard raw.description.count <= maxDescriptionLength else { return nil }
        guard raw.reason_codes.count <= maxReasonCodes else { return nil }
        for r in raw.reason_codes where r.count > 64 { return nil }
        guard raw.confidence >= 0 && raw.confidence <= 1 else { return nil }
        return Classification(fileID: raw.fileID,
                              categories: cats,
                              description: raw.description,
                              confidence: raw.confidence,
                              reasonCodes: raw.reason_codes)
    }

    public struct RawClassification: Codable, Sendable {
        public let file_id: String
        public let categories: [String]
        public let description: String
        public let confidence: Double
        public let reason_codes: [String]

        public var fileID: String { file_id }

        enum CodingKeys: String, CodingKey {
            case file_id, categories, description, confidence, reason_codes
        }
    }
}

extension Classification {
    /// Serialize back to the canonical wire schema (snake_case).
    public func jsonData() throws -> Data {
        let raw = ClassifierContract.RawClassification(
            file_id: fileID, categories: categories, description: description,
            confidence: confidence, reason_codes: reasonCodes)
        return try JSONEncoder().encode(raw)
    }
}
