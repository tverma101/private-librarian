import Foundation
import XCTest
@testable import LibrarianCore

final class SearchScaleTests: XCTestCase {
    private struct ScaleProvider: EmbeddingProvider {
        let providerID = "scale-test-provider"
        var preflight: EmbeddingProviderPreflight {
            EmbeddingProviderPreflight(providerID: providerID, available: true, reason: "synthetic")
        }
        func embedText(_ text: String) -> EmbeddingVector? {
            EmbeddingVector(spaceID: textModelID, dim: 2, data: Self.vector(1, 0))
        }
        func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
            EmbeddingVector(spaceID: imageModelID, dim: 2, data: Self.vector(1, 0))
        }
        func embedJointText(_ text: String) -> EmbeddingVector? {
            EmbeddingVector(spaceID: imageModelID, dim: 2, data: Self.vector(1, 0))
        }
        static func vector(_ x: Float, _ y: Float) -> Data {
            let values = [x, y]
            return values.withUnsafeBytes { Data($0) }
        }
    }

    private func seed(_ catalog: Catalog, count: Int, model: String) throws {
        for index in 0..<count {
            let id = "scale-\(index)"
            let identity = FileIdentity(
                path: "/tmp/search-scale/file-\(index).txt",
                volumeUUID: nil,
                fileID: UInt64(index + 1),
                size: 32,
                mtime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                ctime: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                kind: .text,
                isSymlink: false
            )
            try catalog.upsertFile(identity: identity, id: id)
            try catalog.setStatus(fileID: id, status: "indexed")

            // The best match deliberately lives in the third SQL batch (>1024)
            // so this is a correctness regression for keyset pagination.
            let vector: Data
            if index == count - 1 {
                vector = ScaleProvider.vector(1, 0)
            } else if index == count - 2 {
                vector = ScaleProvider.vector(0.95, 0.3122499)
            } else {
                vector = ScaleProvider.vector(0, 1)
            }
            try catalog.saveEmbedding(fileID: id, model: model, dim: 2, vector: vector)
        }
    }

    func testSemanticSearchFindsWinnerBeyondFirstTwoVectorBatches() throws {
        let catalog = try TestSupport.makeCatalog()
        let provider = ScaleProvider()
        try seed(catalog, count: 1_300, model: provider.textModelID)

        let service = SearchService(catalog: catalog, enableLocalEmbeddings: true,
                                    embeddingProvider: provider)
        let hits = try service.semanticSearch(query: "browser engine", limit: 5, threshold: 0.5)

        XCTAssertEqual(hits.first?.fileID, "scale-1299")
        XCTAssertTrue(hits.contains { $0.fileID == "scale-1298" })
        XCTAssertLessThanOrEqual(hits.count, 5)
    }

    func testCrossModalSearchFindsWinnerBeyondFirstTwoVectorBatches() throws {
        let catalog = try TestSupport.makeCatalog()
        let provider = ScaleProvider()
        try seed(catalog, count: 1_300, model: provider.imageModelID)

        let service = SearchService(catalog: catalog, enableLocalEmbeddings: true,
                                    embeddingProvider: provider)
        let hits = try service.clipTextToImageSearch(query: "browser screenshot", limit: 3, threshold: 0.5)

        XCTAssertEqual(hits.first?.fileID, "scale-1299")
        XCTAssertTrue(hits.contains { $0.fileID == "scale-1298" })
        XCTAssertLessThanOrEqual(hits.count, 3)
    }
}
