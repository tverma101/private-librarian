import XCTest
@testable import LibrarianCore

final class ASRStateRegressionTests: XCTestCase {
    private final class ScriptedProvider: StatefulSpeechTranscriptionProvider, @unchecked Sendable {
        let providerID = "fixture-stateful"
        let processingIdentity: String
        private let lock = NSLock()
        private var attempts: [TranscriptionAttempt]
        private(set) var calls = 0

        init(identity: String, attempts: [TranscriptionAttempt]) {
            self.processingIdentity = identity
            self.attempts = attempts
        }

        func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]? {
            switch transcribeStatefully(chunks) {
            case .success(let segments): return segments
            case .noTranscript, .failure: return nil
            }
        }

        func transcribeStatefully(_ chunks: [PCMChunk]) -> TranscriptionAttempt {
            lock.lock()
            defer { lock.unlock() }
            calls += 1
            if attempts.isEmpty { return .noTranscript }
            return attempts.removeFirst()
        }
    }

    private final class FixedDecoder: PCMDecoding, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0

        func decode(snapshot: Data, onChunk: (PCMChunk) throws -> Void) throws {
            lock.lock(); calls += 1; lock.unlock()
            try onChunk(PCMChunk(
                samples: [Float](repeating: 0.15, count: 32_000),
                sampleRate: 16_000,
                channels: 1,
                startTime: 0))
        }
    }

    func testProviderIdentityChangeReindexesOnceThenReturnsToZeroWork() throws {
        let fixture = try makeFixture(named: "provider-change.wav")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalog = try TestSupport.makeCatalog(tag: "asr-id-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.enableOCR = false

        let disabledDecoder = FixedDecoder()
        let disabled = Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: DisabledSpeechTranscriptionProvider(), pcmDecoder: disabledDecoder)
        XCTAssertTrue(try disabled.indexOne(path: fixture.file.path))
        XCTAssertEqual(disabledDecoder.calls, 0)

        let firstProvider = ScriptedProvider(
            identity: "fixture:model-a",
            attempts: [.success([segment("alpha provider transcript")])])
        let firstDecoder = FixedDecoder()
        let first = Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: firstProvider, pcmDecoder: firstDecoder)
        XCTAssertTrue(try first.indexOne(path: fixture.file.path),
                      "disabled -> real provider must invalidate the unchanged file")
        XCTAssertEqual(firstProvider.calls, 1)
        XCTAssertEqual(firstDecoder.calls, 1)

        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == fixture.file.path })
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text), ["alpha provider transcript"])

        let sameIdentity = ScriptedProvider(
            identity: "fixture:model-a",
            attempts: [.success([segment("should never run")])])
        let sameDecoder = FixedDecoder()
        let unchanged = Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: sameIdentity, pcmDecoder: sameDecoder)
        XCTAssertFalse(try unchanged.indexOne(path: fixture.file.path))
        XCTAssertEqual(sameIdentity.calls, 0)
        XCTAssertEqual(sameDecoder.calls, 0)

        let changedProvider = ScriptedProvider(
            identity: "fixture:model-b",
            attempts: [.success([segment("beta provider transcript")])])
        let changedDecoder = FixedDecoder()
        let changed = Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: changedProvider, pcmDecoder: changedDecoder)
        XCTAssertTrue(try changed.indexOne(path: fixture.file.path),
                      "provider/model identity change must invalidate once")
        XCTAssertEqual(changedProvider.calls, 1)
        XCTAssertEqual(changedDecoder.calls, 1)
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text), ["beta provider transcript"])
    }

    func testProviderFailureStaysPendingAndSuccessfulRetryCommits() throws {
        let fixture = try makeFixture(named: "retry.wav")
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let catalog = try TestSupport.makeCatalog(tag: "asr-retry-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.enableOCR = false

        let initial = ScriptedProvider(
            identity: "fixture:model-stable",
            attempts: [.success([segment("old retained transcript")])])
        XCTAssertTrue(try Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: initial, pcmDecoder: FixedDecoder())
            .indexOne(path: fixture.file.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == fixture.file.path })
        XCTAssertTrue(try catalog.searchExact("retained").contains { $0.fileID == row.id })

        // Change the source so the same provider identity gets another attempt.
        try makeWAV(seconds: 3, amplitude: 7_000).write(to: fixture.file, options: .atomic)
        let failing = ScriptedProvider(
            identity: "fixture:model-stable",
            attempts: [.failure("fixture transient failure")])
        XCTAssertTrue(try Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: failing, pcmDecoder: FixedDecoder())
            .indexOne(path: fixture.file.path))

        let pending = try XCTUnwrap(try catalog.allFiles().first { $0.id == row.id })
        XCTAssertEqual(pending.status, "pending")
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text), ["old retained transcript"],
                       "pending generation may retain old rows for retry bookkeeping")
        XCTAssertFalse(try catalog.searchExact("retained").contains { $0.fileID == row.id },
                       "pending files must not present retained transcript as current")

        let retry = ScriptedProvider(
            identity: "fixture:model-stable",
            attempts: [.success([segment("new retry transcript")])])
        XCTAssertTrue(try Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: retry, pcmDecoder: FixedDecoder())
            .indexOne(path: fixture.file.path),
                      "pending status must remain retryable even when bytes are unchanged")
        XCTAssertEqual(retry.calls, 1)
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text), ["new retry transcript"])
        XCTAssertTrue(try catalog.searchExact("retry").contains { $0.fileID == row.id })

        try makeWAV(seconds: 4, amplitude: 5_000).write(to: fixture.file, options: .atomic)
        let definitiveEmpty = ScriptedProvider(
            identity: "fixture:model-stable",
            attempts: [.noTranscript])
        XCTAssertTrue(try Indexer(
            broker: SourceBroker(), catalog: catalog, scheduler: Scheduler(), options: options,
            transcriptionProvider: definitiveEmpty, pcmDecoder: FixedDecoder())
            .indexOne(path: fixture.file.path))
        XCTAssertTrue(try catalog.transcripts(forFile: row.id).isEmpty,
                      "definitive no-transcript result should clear the old generation")
    }

    private static func segment(_ text: String) -> TranscriptSegment {
        TranscriptSegment(start: 0, end: 1.5, text: text, confidence: 0.99)
    }

    private func segment(_ text: String) -> TranscriptSegment { Self.segment(text) }

    private func makeFixture(named name: String) throws -> (root: URL, file: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("asr-state-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent(name)
        try Self.makeWAV(seconds: 2, amplitude: 8_000).write(to: file)
        return (root, file)
    }

    private static func makeWAV(sampleRate: Int = 16_000, seconds: Int, amplitude: Int16) -> Data {
        let sampleCount = sampleRate * seconds
        var pcm = Data()
        pcm.reserveCapacity(sampleCount * 2)
        for index in 0..<sampleCount {
            let phase = Double(index % 200) / 200.0
            let wave = sin(phase * .pi * 2)
            var value = Int16(Double(amplitude) * wave).littleEndian
            withUnsafeBytes(of: &value) { pcm.append(contentsOf: $0) }
        }

        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(36 + pcm.count))
        wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLE(UInt32(16))
        appendLE(UInt16(1))
        appendLE(UInt16(1))
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))
        appendLE(UInt16(2))
        appendLE(UInt16(16))
        wav.append(contentsOf: Data("data".utf8))
        appendLE(UInt32(pcm.count))
        wav.append(pcm)
        return wav
    }
}
