import XCTest
@testable import LibrarianCore

final class LocalModelRouterTests: XCTestCase {
    func testRegistryHasUniqueStableIdentities() {
        let models = LocalModelStack.all
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        XCTAssertEqual(Set(models.map(\.hfID)).count, models.count)
        for model in models {
            XCTAssertFalse(model.id.isEmpty)
            XCTAssertTrue(model.hfID.contains("/"))
            XCTAssertGreaterThanOrEqual(model.revisionPrefix.count, 7)
            XCTAssertTrue(model.revisionPrefix.allSatisfy(\.isHexDigit))
        }
    }

    func testFastProfileNeverRoutesGenerativeModels() {
        let router = LocalModelRouter(profile: .fast)
        let available = Set(LocalModelStack.all.map(\.id))
        let route = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.1,
                                            hasUsefulText: true,
                                            nativeOCRSucceeded: false,
                                            isDocumentLikeImage: true),
            availableModelIDs: available)
        XCTAssertEqual(route.map(\.id), [LocalModelStack.siglip2.id, LocalModelStack.dinov3.id])
        XCTAssertTrue(route.allSatisfy { $0.capability == .imageSemantic || $0.capability == .visualSimilarity })
    }

    func testBalancedUsesCheapEmbeddingsThenOnlyNeededSpecialists() {
        let router = LocalModelRouter(profile: .balanced)
        let available = Set(LocalModelStack.all.map(\.id))
        let ambiguous = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.2,
                                            hasUsefulText: false,
                                            nativeOCRSucceeded: false,
                                            isDocumentLikeImage: true),
            availableModelIDs: available)
        XCTAssertEqual(ambiguous.map(\.id), [
            LocalModelStack.siglip2.id,
            LocalModelStack.dinov3.id,
            LocalModelStack.paddleOCR.id,
            LocalModelStack.miniCPM.id,
        ])

        let clear = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.9,
                                            hasUsefulText: true,
                                            nativeOCRSucceeded: true,
                                            isDocumentLikeImage: false),
            availableModelIDs: available)
        XCTAssertEqual(clear.map(\.id), [LocalModelStack.siglip2.id, LocalModelStack.dinov3.id])
    }

    func testQualityHeavyFallbacksOnlyAppearForAmbiguity() {
        let router = LocalModelRouter(profile: .quality)
        let available = Set(LocalModelStack.all.map(\.id))
        let clear = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.95,
                                            hasUsefulText: true,
                                            nativeOCRSucceeded: true,
                                            isDocumentLikeImage: false),
            availableModelIDs: available)
        XCTAssertFalse(clear.contains { $0.cost == .heavy })

        let ambiguous = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.1,
                                            hasUsefulText: true,
                                            nativeOCRSucceeded: true,
                                            isDocumentLikeImage: false),
            availableModelIDs: available)
        XCTAssertTrue(ambiguous.contains { $0.id == LocalModelStack.lfm.id })
        XCTAssertEqual(ambiguous.filter { $0.cost == .heavy }.map(\.id), [LocalModelStack.lfm.id])
    }

    func testRegistryExcludesModelsThatCannotRespectMacMemoryCeiling() {
        let ids = Set(LocalModelStack.all.map(\.id))
        XCTAssertFalse(ids.contains("ling-3.0-tiny"))
        XCTAssertFalse(ids.contains("internvl3.5-4b"))
        XCTAssertFalse(ids.contains("mimo-vl-7b-rl-2508"))
    }

    func testUnavailableModelsAreNeverSubstituted() {
        let router = LocalModelRouter(profile: .quality)
        let route = router.route(
            context: LocalModelRouteContext(kind: .image, confidence: 0.1,
                                            hasUsefulText: true,
                                            nativeOCRSucceeded: false,
                                            isDocumentLikeImage: true),
            availableModelIDs: [LocalModelStack.miniCPM.id])
        XCTAssertEqual(route.map(\.id), [LocalModelStack.miniCPM.id])
    }

    func testPDFNeverRoutesImageOnlyOCRSpecialist() {
        let router = LocalModelRouter(profile: .balanced)
        let available = Set(LocalModelStack.all.map(\.id))
        let route = router.route(
            context: LocalModelRouteContext(kind: .pdf, confidence: 0.1,
                                            hasUsefulText: false,
                                            nativeOCRSucceeded: false,
                                            isDocumentLikeImage: true),
            availableModelIDs: available)
        XCTAssertFalse(route.contains { $0.id == LocalModelStack.paddleOCR.id })
        XCTAssertFalse(route.contains { $0.capability == .visionFallback })
    }

    func testSigLIPAndDINOUseDifferentSpacesAndDimensions() {
        XCTAssertNotEqual(SpecialistModelBridge.siglipSpaceID, SpecialistModelBridge.dinoSpaceID)
        XCTAssertNotEqual(SpecialistModelBridge.siglipDimension, SpecialistModelBridge.dinoDimension)
        XCTAssertEqual(SpecialistModelBridge.siglipDimension, 1152)
        XCTAssertEqual(SpecialistModelBridge.dinoDimension, 768)
    }
}
