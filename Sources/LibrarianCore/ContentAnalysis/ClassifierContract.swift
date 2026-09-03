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
        self.categories = categories
        self.description = description
        self.confidence = confidence
        self.reasonCodes = reasonCodes
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
