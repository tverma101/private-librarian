import Foundation

/// Conservative directory-name policy used for whole-computer onboarding.
/// These names are skipped wherever they occur, while explicit root and
/// user-prefix exclusions remain separately visible in coverage reporting.
public enum OnboardingExclusions {
    public static let defaultDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn", ".bzr",
        "node_modules", "DerivedData", "build", ".build", "dist",
        "Pods", "Carthage", ".swiftpm", ".cache", "Caches", "__pycache__",
        ".Trash"
    ]

    public static func defaultPaths(catalogPath: String? = nil,
                                    modelPaths: [String] = []) -> [String] {
        var paths: [String] = []
        func add(_ path: String) {
            let normalized = path.count > 1 && path.hasSuffix("/")
                ? String(path.dropLast()) : path
            guard !normalized.isEmpty, !paths.contains(normalized) else { return }
            paths.append(normalized)
        }
        if let catalogPath {
            add((catalogPath as NSString).deletingLastPathComponent)
        }
        for path in modelPaths { add(path) }
        add(NSTemporaryDirectory())
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            add(caches.path)
        }
        return paths.sorted()
    }
}

public struct OnboardingRootCoverage: Codable, Sendable, Equatable, Identifiable {
    public let root: String
    public let eligibleFiles: Int
    public let indexedFiles: Int
    public let reviewFiles: Int
    public let missingFiles: Int
    public let skippedFiles: Int
    public let exclusionReasons: [String: Int]

    public var id: String { root }

    public init(root: String, eligibleFiles: Int, indexedFiles: Int,
                reviewFiles: Int, missingFiles: Int, skippedFiles: Int,
                exclusionReasons: [String: Int] = [:]) {
        self.root = root
        self.eligibleFiles = eligibleFiles
        self.indexedFiles = indexedFiles
        self.reviewFiles = reviewFiles
        self.missingFiles = missingFiles
        self.skippedFiles = skippedFiles
        self.exclusionReasons = exclusionReasons
    }
}

public struct OnboardingCoverage: Codable, Sendable, Equatable {
    public let authorizedRoots: Int
    public let excludedRoots: Int
    public let catalogedFiles: Int
    public let indexedFiles: Int
    public let reviewFiles: Int
    public let missingFiles: Int
    public let excludedCatalogRows: Int
    public let roots: [OnboardingRootCoverage]

    public init(authorizedRoots: Int, excludedRoots: Int, catalogedFiles: Int,
                indexedFiles: Int, reviewFiles: Int, missingFiles: Int,
                excludedCatalogRows: Int, roots: [OnboardingRootCoverage] = []) {
        self.authorizedRoots = authorizedRoots
        self.excludedRoots = excludedRoots
        self.catalogedFiles = catalogedFiles
        self.indexedFiles = indexedFiles
        self.reviewFiles = reviewFiles
        self.missingFiles = missingFiles
        self.excludedCatalogRows = excludedCatalogRows
        self.roots = roots
    }

    public static let empty = OnboardingCoverage(
        authorizedRoots: 0, excludedRoots: 0, catalogedFiles: 0,
        indexedFiles: 0, reviewFiles: 0, missingFiles: 0, excludedCatalogRows: 0,
        roots: []
    )
}

public struct CatalogDashboard: Codable, Sendable, Equatable {
    public let total: Int
    public let indexed: Int
    public let review: Int
    public let missing: Int
    public let categories: Int
    public let duplicateGroups: Int
    public let graphEdges: Int

    public init(total: Int, indexed: Int, review: Int, missing: Int,
                categories: Int, duplicateGroups: Int, graphEdges: Int) {
        self.total = total
        self.indexed = indexed
        self.review = review
        self.missing = missing
        self.categories = categories
        self.duplicateGroups = duplicateGroups
        self.graphEdges = graphEdges
    }

    public static let empty = CatalogDashboard(total: 0, indexed: 0, review: 0,
                                                missing: 0, categories: 0,
                                                duplicateGroups: 0, graphEdges: 0)
}
