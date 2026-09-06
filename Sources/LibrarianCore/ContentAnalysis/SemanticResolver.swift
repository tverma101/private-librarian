import Foundation

/// Where a semantic destination hint came from. The resolver weights these
/// differently so one weak sibling can never become a confident Finder move.
public enum SemanticContextSource: String, Codable, Sendable, CaseIterable {
    case sibling
    case similarityCluster
    case userCorrection
    case learnedRule
    case modelJudge
}

/// One inert destination hint. This type deliberately carries no path authority
/// and cannot move files; it is only evidence fed into the classifier contract.
public struct SemanticContextCandidate: Codable, Sendable, Equatable {
    public let category: String
    public let confidence: Double
    public let supportCount: Int
    public let source: SemanticContextSource

    public init(category: String, confidence: Double, supportCount: Int = 1,
                source: SemanticContextSource) {
        self.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        self.confidence = max(0, min(1, confidence))
        self.supportCount = max(1, supportCount)
        self.source = source
    }
}

/// Bounded context supplied by folder population, semantic clusters, learned
/// corrections, or a validated model judge. Empty context preserves the old
/// per-file behavior.
public struct SemanticResolutionContext: Codable, Sendable, Equatable {
    public let candidates: [SemanticContextCandidate]

    public init(candidates: [SemanticContextCandidate] = []) {
        self.candidates = Array(candidates.prefix(64))
    }

    public static let empty = SemanticResolutionContext()
}

/// Content-first adjudication layer inspired by modern AI file organizers:
/// deterministic extraction stays cheap, while ambiguous files may be resolved
/// from sibling/cluster/user/model evidence. Output remains inert Classification
/// data and must still pass ClassifierContract before anything can materialize.
public struct SemanticResolver: Sendable {
    public static let specialistEscalationThreshold = 0.72

    public init() {}

    public func resolve(base: Classification,
                        context: SemanticResolutionContext = .empty) -> Classification {
        var categories = base.categories
        var reasons = base.reasonCodes
        var confidence = base.confidence

        // Explicit content beats a misleading filename. RuleBasedClassifier
        // emits `text:MAT-171` / `filename:MAT-171` style reason codes, so the
        // resolver can settle the lane without parsing or trusting the path.
        let contentCourses = Set(courseCategories(in: categories).filter { category in
            let token = String(category.dropFirst("School/".count))
            return reasons.contains("text:\(token)")
        })
        if contentCourses.count == 1, let chosen = contentCourses.first {
            let filenameConflict = courseCategories(in: categories).contains { category in
                guard category != chosen else { return false }
                let token = String(category.dropFirst("School/".count))
                return reasons.contains("filename:\(token)")
            }
            if filenameConflict {
                categories.removeAll { isCourseCategory($0) && $0 != chosen }
                reasons.removeAll { $0 == "conflict:course" }
                appendReason("semantic:content-over-filename", to: &reasons)
                confidence = max(confidence, 0.86)
                removeReviewIfResolved(categories: &categories, reasons: reasons)
            }
        }

        if let winner = contextualWinner(context.candidates), isSafeCategory(winner.category) {
            if isCourseCategory(winner.category) {
                categories.removeAll { isCourseCategory($0) && $0 != winner.category }
            } else if isImageSubject(winner.category) {
                categories.removeAll { isImageSubject($0) && $0 != winner.category }
            } else if isScreenshotSubtype(winner.category) {
                categories.removeAll { isScreenshotSubtype($0) && $0 != winner.category }
            }
            if !categories.contains(winner.category) {
                categories.append(winner.category)
            }

            switch winner.source {
            case .modelJudge:
                appendReason("specialist:semantic-judge", to: &reasons)
                appendReason("model:pick:\(winner.category)", to: &reasons)
            case .userCorrection:
                appendReason("semantic:user-correction", to: &reasons)
            case .learnedRule:
                appendReason("semantic:learned-rule", to: &reasons)
            case .similarityCluster:
                appendReason("semantic:cluster-consensus", to: &reasons)
            case .sibling:
                appendReason("semantic:sibling-consensus", to: &reasons)
            }
            confidence = max(confidence, winner.score)
            if winner.score >= 0.88 {
                removeReviewIfResolved(categories: &categories, reasons: reasons)
            }
        }

        // Generic type-only answers are not semantic destinations. Keep them
        // below the existing specialist threshold so Balanced/Quality can ask
        // the VLM/LLM judge instead of silently filing `document.pdf` as PDF.
        let meaningful = categories.filter { !Self.genericCategories.contains($0) && $0 != "Review" }
        if meaningful.isEmpty {
            confidence = min(confidence, 0.69)
            appendReason("semantic:needs-judge", to: &reasons)
        }

        if categories.count > ClassifierContract.maxCategories {
            categories = Array(categories.prefix(ClassifierContract.maxCategories))
        }
        reasons = Array(reasons.prefix(ClassifierContract.maxReasonCodes))
        return Classification(fileID: base.fileID,
                              categories: categories,
                              description: base.description,
                              confidence: min(0.99, confidence),
                              reasonCodes: reasons)
    }

    private struct Winner {
        let category: String
        let source: SemanticContextSource
        let score: Double
    }

    private func contextualWinner(_ candidates: [SemanticContextCandidate]) -> Winner? {
        struct Aggregate {
            var weightedMax: Double = 0
            var support = 0
            var strongestSource: SemanticContextSource = .sibling
        }

        var byCategory: [String: Aggregate] = [:]
        for candidate in candidates.prefix(64) where isSafeCategory(candidate.category) && candidate.category != "Review" {
            let weight: Double
            switch candidate.source {
            // Folder population is useful only as a repeated pattern. A single
            // sibling can never decide, but three independently classified
            // siblings can provide enough evidence to rescue a vague filename.
            case .sibling: weight = 0.86
            // Semantic clusters have already passed embedding thresholds, so
            // two agreeing peers are stronger than plain folder proximity.
            case .similarityCluster: weight = 0.92
            case .learnedRule: weight = 0.90
            case .modelJudge: weight = 0.97
            case .userCorrection: weight = 1.0
            }
            let weighted = candidate.confidence * weight
            var aggregate = byCategory[candidate.category] ?? Aggregate()
            if weighted >= aggregate.weightedMax {
                aggregate.weightedMax = weighted
                aggregate.strongestSource = candidate.source
            }
            aggregate.support += candidate.supportCount
            byCategory[candidate.category] = aggregate
        }

        let ranked: [Winner] = byCategory.map { category, aggregate in
            let corroboration = min(0.12, Double(max(0, aggregate.support - 1)) * 0.03)
            return Winner(category: category,
                          source: aggregate.strongestSource,
                          score: min(0.97, aggregate.weightedMax + corroboration))
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.category < $1.category
        }

        guard let first = ranked.first else { return nil }
        let support = byCategory[first.category]?.support ?? 0
        let minimumSupport: Int
        switch first.source {
        case .sibling: minimumSupport = 3
        case .similarityCluster: minimumSupport = 2
        case .userCorrection, .modelJudge, .learnedRule: minimumSupport = 1
        }
        guard first.score >= 0.78, support >= minimumSupport else { return nil }

        // Conflicting context with a nearly tied runner-up is ambiguity, not
        // permission to pick whichever dictionary entry happened to win.
        if let second = ranked.dropFirst().first,
           second.category != first.category,
           second.score >= first.score - 0.05,
           mutuallyExclusive(first.category, second.category) {
            return nil
        }
        return first
    }

    private func courseCategories(in categories: [String]) -> [String] {
        categories.filter(isCourseCategory)
    }

    private func isCourseCategory(_ category: String) -> Bool {
        let prefix = "School/"
        guard category.hasPrefix(prefix) else { return false }
        let value = String(category.dropFirst(prefix.count))
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        return pieces.count == 2
            && pieces[0].count >= 2
            && pieces[0].allSatisfy(\.isLetter)
            && (3...4).contains(pieces[1].count)
            && pieces[1].allSatisfy(\.isNumber)
    }

    private func isImageSubject(_ category: String) -> Bool {
        Self.imageSubjects.contains(category)
    }

    private func isScreenshotSubtype(_ category: String) -> Bool {
        category.hasPrefix("Screenshots/") && category.count > "Screenshots/".count
    }

    private func mutuallyExclusive(_ lhs: String, _ rhs: String) -> Bool {
        (isCourseCategory(lhs) && isCourseCategory(rhs))
            || (isImageSubject(lhs) && isImageSubject(rhs))
            || (isScreenshotSubtype(lhs) && isScreenshotSubtype(rhs))
    }

    private func isSafeCategory(_ category: String) -> Bool {
        guard !category.isEmpty, category.count <= 64,
              category.first?.isLetter == true || category.first?.isNumber == true,
              !category.contains("..") else { return false }
        let punctuation: Set<Character> = [" ", "/", ".", "_", "-"]
        return category.allSatisfy { $0.isLetter || $0.isNumber || punctuation.contains($0) }
    }

    private func appendReason(_ reason: String, to reasons: inout [String]) {
        guard reason.count <= 64, !reasons.contains(reason),
              reasons.count < ClassifierContract.maxReasonCodes else { return }
        reasons.append(reason)
    }

    private func removeReviewIfResolved(categories: inout [String], reasons: [String]) {
        let stillNeedsReview = reasons.contains("kind:unknown")
            || reasons.contains("cloud-placeholder")
            || reasons.contains("conflict:image-subject")
            || reasons.contains(where: { $0.contains("uncertain") })
        if !stillNeedsReview {
            categories.removeAll { $0 == "Review" }
        }
    }

    private static let genericCategories: Set<String> = [
        "Image", "Audio", "Video", "Documents/PDF", "Documents/Text", "Documents/Office",
        "Archives", "DiskImages", "Applications", "Packages", "Links"
    ]

    private static let imageSubjects: Set<String> = [
        "Image/Animals", "Image/Vehicles", "Image/Scenery", "Image/Food", "Image/Documents"
    ]
}
