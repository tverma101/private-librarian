import Foundation

/// Catalog-only actions exposed by the review UI. They change encrypted
/// membership/override rows, never the original file.
public enum ReviewCorrectionAction: String, Codable, Sendable, Equatable, CaseIterable {
    case addCategory
    case removeCategory
    case markUnknown
}

public struct ReviewItem: Codable, Sendable, Equatable, Identifiable {
    public let fileID: String
    public let path: String
    public let confidence: Double
    public let categories: [String]
    public let reasonCodes: [String]
    public let state: String
    public let updated: Double

    public var id: String { fileID }

    public init(fileID: String, path: String, confidence: Double,
                categories: [String], reasonCodes: [String], state: String,
                updated: Double) {
        self.fileID = fileID
        self.path = path
        self.confidence = confidence
        self.categories = categories
        self.reasonCodes = reasonCodes
        self.state = state
        self.updated = updated
    }
}

public struct ReviewSummary: Codable, Sendable, Equatable {
    public let open: Int
    public let resolved: Int

    public init(open: Int, resolved: Int) {
        self.open = open
        self.resolved = resolved
    }
}
