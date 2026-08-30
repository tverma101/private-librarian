import Foundation

/// Conservative directory-name policy used for whole-computer onboarding.
/// These names are skipped wherever they occur, while explicit root and
/// user-prefix exclusions remain separately visible in coverage reporting.
public enum OnboardingExclusions {
    public static let defaultDirectoryNames: Set<String> = [
        // Version-control and dependency trees.
        ".git", ".hg", ".svn", ".bzr",
        "node_modules", "Pods", "Carthage", ".swiftpm",

        // General build output and compiler caches.
        "DerivedData", "build", ".build", "dist", "out", "obj", "target",
        "WebKitBuild", "buck-out", ".cxx", ".ccache", ".sccache",
        "bazel-bin", "bazel-out", "bazel-testlogs",
        "cmake-build-debug", "cmake-build-release", "cmake-build-relwithdebinfo",
        "cmake-build-minsizerel",

        // Package-manager/framework caches that can contain enormous trees of
        // third-party/generated files on developer machines.
        ".gradle", ".m2", ".npm", ".yarn", ".pnpm-store", ".cargo", ".rustup",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache", ".vite",
        ".mozbuild",

        // Generic caches/runtime noise.
        ".cache", "Caches", "__pycache__", ".Trash"
    ]

    /// Some build systems create configuration-specific directory names rather
    /// than one stable basename (for example Firefox `obj-*`, CMake
    /// `cmake-build-*`, and Bazel's `bazel-*` symlink/output trees).
    public static func isExcludedDirectoryName(
        _ name: String,
        configured: Set<String> = defaultDirectoryNames
    ) -> Bool {
        if configured.contains(name) { return true }
        let lower = name.lowercased()
        return lower.hasPrefix("obj-")
            || lower.hasPrefix("cmake-build-")
            || lower.hasPrefix("bazel-")
    }

    /// Files that are implementation noise rather than stable user content.
    /// Browser partial downloads are ignored until the browser atomically
    /// renames them to their completed filename; Finder metadata and Office
    /// lock files should never become Review/Smart Group clutter.
    public static func isTransientOrSystemFile(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        if name == ".DS_Store" || name == ".localized" { return true }
        if name.hasPrefix("._") || name.hasPrefix("~$") { return true }
        return [".crdownload", ".download", ".part", ".partial"].contains {
            lower.hasSuffix($0)
        }
    }

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
