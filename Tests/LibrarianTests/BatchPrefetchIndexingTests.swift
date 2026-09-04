import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import LibrarianCore

final class BatchPrefetchIndexingTests: XCTestCase {
    func testNewImageWindowUsesOneGroupedBatchAndConsumesCachedVectors() throws {
        let fixture = try makeImageFixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let provider = FakePrefetchEmbeddingProvider(preferredBatchSize: 4)
        let (catalog, session) = try makeSession(provider: provider)
        _ = catalog

        let result = try session.indexRoot(fixture.root)
        let metrics = provider.metrics

        XCTAssertEqual(result.processed, 4)
        XCTAssertEqual(metrics.primeCalls, 1)
        XCTAssertEqual(metrics.primeSizes, [4])
        XCTAssertEqual(metrics.cacheHits, 4)
        XCTAssertEqual(metrics.singleCalls, 0)
        XCTAssertEqual(metrics.batchIDs.count, 4)
        XCTAssertTrue(metrics.batchIDs.allSatisfy {
            $0.range(of: #"^file_[0-9a-f]{12}$"#, options: .regularExpression) != nil
        })
        XCTAssertTrue(metrics.batchIDs.allSatisfy { !$0.contains(fixture.root.lastPathComponent) },
                      "specialist batch IDs must remain opaque and path-free")
    }

    func testUnchangedSecondPassWithCurrentEmbeddingDoesZeroPrefetchInference() throws {
        let fixture = try makeImageFixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let provider = FakePrefetchEmbeddingProvider(preferredBatchSize: 4)
        let (_, session) = try makeSession(provider: provider)
        let first = try session.indexRoot(fixture.root)
        XCTAssertEqual(first.processed, 4)

        provider.resetMetrics()
        let second = try session.indexRoot(fixture.root)
        let metrics = provider.metrics

        XCTAssertEqual(second.processed, 0)
        XCTAssertEqual(metrics.primeCalls, 0)
        XCTAssertEqual(metrics.cacheHits, 0)
        XCTAssertEqual(metrics.singleCalls, 0)
    }

    func testBatchFailureFallsBackToExistingSingleImagePath() throws {
        let fixture = try makeImageFixture(count: 4)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let provider = FakePrefetchEmbeddingProvider(preferredBatchSize: 4, failPrime: true)
        let (_, session) = try makeSession(provider: provider)
        let result = try session.indexRoot(fixture.root)
        let metrics = provider.metrics

        XCTAssertEqual(result.processed, 4)
        XCTAssertEqual(metrics.primeCalls, 1)
        XCTAssertEqual(metrics.primeSizes, [4])
        XCTAssertEqual(metrics.cacheHits, 0)
        XCTAssertEqual(metrics.singleCalls, 4,
                       "batch failure must preserve the old per-image fallback")
    }

    func testChangedBytesAfterPrefetchCannotConsumeStaleCachedVector() throws {
        let fixture = try makeImageFixture(count: 2)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let provider = FakePrefetchEmbeddingProvider(preferredBatchSize: 2)
        provider.onPrime = { [first = fixture.files[0]] in
            if let replacement = try? Self.jpegFixture(variant: 99) {
                try? replacement.write(to: first, options: .atomic)
            }
        }
        let (_, session) = try makeSession(provider: provider)
        let result = try session.indexRoot(fixture.root)
        let metrics = provider.metrics

        XCTAssertEqual(result.processed, 2)
        XCTAssertEqual(metrics.primeCalls, 1)
        XCTAssertEqual(metrics.cacheHits, 1,
                       "the unchanged image should consume its prefetched vector")
        XCTAssertEqual(metrics.singleCalls, 1,
                       "changed bytes must miss the content-keyed cache and run fresh inference")
    }

    private func makeSession(
        provider: FakePrefetchEmbeddingProvider
    ) throws -> (Catalog, ScalableIndexSession) {
        let catalog = try TestSupport.makeCatalog()
        let broker = SourceBroker()
        var indexOptions = Indexer.Options()
        indexOptions.enableLocalEmbeddings = true
        indexOptions.enableOCR = false
        indexOptions.localModelProfile = .balanced
        let indexer = Indexer(
            broker: broker,
            catalog: catalog,
            scheduler: Scheduler(),
            options: indexOptions,
            embeddingProvider: provider)
        var sessionOptions = ScalableIndexSession.Options()
        sessionOptions.batchSize = 32
        sessionOptions.updateSimilarity = false
        return (
            catalog,
            ScalableIndexSession(
                broker: broker,
                catalog: catalog,
                indexer: indexer,
                options: sessionOptions))
    }

    private func makeImageFixture(count: Int) throws -> (root: URL, files: [URL]) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var files: [URL] = []
        for index in 0..<count {
            let file = root.appendingPathComponent(String(format: "shot-%02d.jpg", index))
            try Self.jpegFixture(variant: index).write(to: file)
            files.append(file)
        }
        return (root, files)
    }

    private static func jpegFixture(variant: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 96,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw FixtureError.imageUnavailable
        }
        let component = CGFloat((variant % 10) + 1) / 11.0
        context.setFillColor(red: component, green: 0.25, blue: 1.0 - component, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 8 + variant % 12, y: 8, width: 30, height: 14))
        guard let image = context.makeImage() else { throw FixtureError.imageUnavailable }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "public.jpeg" as CFString, 1, nil) else {
            throw FixtureError.imageUnavailable
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.imageUnavailable }
        return output as Data
    }

    private enum FixtureError: Error {
        case imageUnavailable
    }
}

private final class FakePrefetchEmbeddingProvider: PrefetchingBatchImageEmbeddingProvider, @unchecked Sendable {
    struct Metrics: Equatable {
        var primeCalls = 0
        var primeSizes: [Int] = []
        var cacheHits = 0
        var singleCalls = 0
        var batchIDs: [String] = []
    }

    let providerID = "test-prefetch-image-v1"
    let preferredBatchSize: Int
    let failPrime: Bool
    var onPrime: (() -> Void)?

    private let lock = NSLock()
    private var state = Metrics()
    private var cache: [Data: [EmbeddingVector]] = [:]

    init(preferredBatchSize: Int, failPrime: Bool = false) {
        self.preferredBatchSize = preferredBatchSize
        self.failPrime = failPrime
    }

    var preflight: EmbeddingProviderPreflight {
        EmbeddingProviderPreflight(
            providerID: providerID,
            available: true,
            reason: "deterministic test provider")
    }

    var metrics: Metrics {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func resetMetrics() {
        lock.lock()
        state = Metrics()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    func embedText(_ text: String) -> EmbeddingVector? { vector() }
    func embedJointText(_ text: String) -> EmbeddingVector? { vector() }

    func embedImageBytes(_ bytes: Data) -> EmbeddingVector? {
        lock.lock()
        if var vectors = cache.removeValue(forKey: bytes), let first = vectors.first {
            vectors.removeFirst()
            if !vectors.isEmpty { cache[bytes] = vectors }
            state.cacheHits += 1
            lock.unlock()
            return first
        }
        state.singleCalls += 1
        lock.unlock()
        return vector()
    }

    func embedImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        items.map { SpecialistImageEmbeddingBatchResult(id: $0.id, vector: vector()) }
    }

    @discardableResult
    func primeImageBatch(
        _ items: [SpecialistImageEmbeddingBatchItem],
        timeout: TimeInterval
    ) -> [SpecialistImageEmbeddingBatchResult]? {
        lock.lock()
        state.primeCalls += 1
        state.primeSizes.append(items.count)
        state.batchIDs.append(contentsOf: items.map(\.id))
        lock.unlock()

        if failPrime { return nil }
        let results = embedImageBatch(items, timeout: timeout) ?? []
        guard results.count == items.count else { return nil }

        lock.lock()
        for (item, result) in zip(items, results) {
            cache[item.bytes, default: []].append(result.vector)
        }
        lock.unlock()
        onPrime?()
        return results
    }

    func clearPrefetchedImages() {
        lock.lock()
        cache.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func vector() -> EmbeddingVector {
        var data = Data()
        for value in [Float(1), Float(0), Float(0), Float(0)] {
            var value = value
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return EmbeddingVector(spaceID: "test-prefetch-joint-v1", dim: 4, data: data)
    }
}
