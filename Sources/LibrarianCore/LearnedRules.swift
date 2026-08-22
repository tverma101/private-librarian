import Foundation

// MARK: - Correction model

public enum CorrectionAction: String, Codable, Sendable, CaseIterable {
    case addCategory = "addCategory"
    case removeCategory = "removeCategory"
    case wrongCategory = "wrongCategory"
}

public struct CorrectionRecord: Codable, Sendable {
    public let fileID: String
    public let category: String
    public let action: CorrectionAction
    public let created: Double
    public let provenance: String
    public init(fileID: String, category: String, action: CorrectionAction, created: Double = Date().timeIntervalSince1970, provenance: String) {
        self.fileID = fileID
        self.category = category
        self.action = action
        self.created = created
        self.provenance = provenance
    }
}

// MARK: - Learned rule model

public enum LearnedPatternType: String, Codable, Sendable, CaseIterable {
    case `extension` = "extension"
    case pathKeyword = "pathKeyword"
    case metadata = "metadata"
}

public struct LearnedRule: Codable, Sendable, Equatable {
    public let id: Int64
    public let patternType: LearnedPatternType
    public let pattern: String
    public let targetCategory: String
    public let confidence: Double
    public let enabled: Bool
    public let provenance: String
    public let created: Double
}

// MARK: - Deterministic rule engine (no ML)

/// Enriches a classification by applying enabled learned rules.
/// Deterministic: no randomness, no model, case-insensitive keyword, suffix for extension.
public struct LearnedRuleEngine: Sendable {
    public let rules: [LearnedRule]

    public init(rules: [LearnedRule]) { self.rules = rules }

    /// Returns the union of categories plus human-inspectable reasons.
    /// - Parameters:
    ///   - categories: base classifier categories
    ///   - evidence: deterministic evidence (filename, extension, metadata)
    ///   - path: optional full path for pathKeyword matching
    public func enrich(categories: [String], evidence: EvidenceExtractor.Evidence, path: String? = nil) -> (categories: [String], reasons: [String]) {
        var cats = categories
        var seen = Set(cats)
        var reasons: [String] = []
        let enabled = rules.filter { $0.enabled }
        for rule in enabled {
            if matches(rule: rule, evidence: evidence, path: path) {
                if seen.insert(rule.targetCategory).inserted {
                    cats.append(rule.targetCategory)
                }
                reasons.append("learned:\(rule.id):\(rule.targetCategory)")
            }
        }
        return (cats, reasons)
    }

    /// File-path + evidence overload used by Indexer (needs path keyword).
    public func enrich(categories: [String], identity: FileIdentity, evidence: EvidenceExtractor.Evidence) -> (categories: [String], reasons: [String]) {
        enrich(categories: categories, evidence: evidence, path: identity.path)
    }

    private func matches(rule: LearnedRule, evidence: EvidenceExtractor.Evidence, path: String?) -> Bool {
        switch rule.patternType {
        case .extension:
            // Suffix match on the file extension (case-insensitive, without dot).
            guard let p = path else { return false }
            let ext = (p as NSString).pathExtension.lowercased()
            let pat = rule.pattern.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !pat.isEmpty else { return false }
            return ext == pat || ext.hasSuffix(pat)
        case .pathKeyword:
            // Case-insensitive substring on full path (and filename tokens as fallback).
            guard let p = path else { return false }
            let pat = rule.pattern.lowercased()
            guard !pat.isEmpty else { return false }
            if p.lowercased().contains(pat) { return true }
            // Also match against joined filename tokens for robustness.
            if evidence.filenameTokens.joined(separator: " ").lowercased().contains(pat) { return true }
            return false
        case .metadata:
            // Case-insensitive substring over kind/sizeClass/notes.
            let pat = rule.pattern.lowercased()
            guard !pat.isEmpty else { return false }
            let hay = ([evidence.kind, evidence.sizeClass] + evidence.notes).joined(separator: " ").lowercased()
            return hay.contains(pat)
        }
    }
}
