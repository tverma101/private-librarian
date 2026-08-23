import Foundation

public struct OnboardingCoverage: Codable, Sendable, Equatable {
    public let authorizedRoots: Int
    public let excludedRoots: Int
    public let catalogedFiles: Int
    public let indexedFiles: Int
    public let reviewFiles: Int
    public let missingFiles: Int
    public let excludedCatalogRows: Int

    public init(authorizedRoots: Int, excludedRoots: Int, catalogedFiles: Int,
                indexedFiles: Int, reviewFiles: Int, missingFiles: Int,
                excludedCatalogRows: Int) {
        self.authorizedRoots = authorizedRoots
        self.excludedRoots = excludedRoots
        self.catalogedFiles = catalogedFiles
        self.indexedFiles = indexedFiles
        self.reviewFiles = reviewFiles
        self.missingFiles = missingFiles
        self.excludedCatalogRows = excludedCatalogRows
    }

    public static let empty = OnboardingCoverage(
        authorizedRoots: 0, excludedRoots: 0, catalogedFiles: 0,
        indexedFiles: 0, reviewFiles: 0, missingFiles: 0, excludedCatalogRows: 0
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
