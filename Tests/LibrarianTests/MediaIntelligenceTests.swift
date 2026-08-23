import XCTest
@testable import LibrarianCore

final class MediaIntelligenceTests: XCTestCase {

    private final class RecordingProvider: SpeechTranscriptionProvider, @unchecked Sendable {
        let providerID = "fixture-provider"
        private let lock = NSLock()
        private(set) var received: [PCMChunk] = []

        func reset() {
            lock.lock()
            received = []
            lock.unlock()
        }

        func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]? {
            lock.lock()
            received = chunks
            lock.unlock()
            guard !chunks.isEmpty, chunks.contains(where: { !$0.samples.isEmpty }) else { return nil }
            return [TranscriptSegment(start: 0, end: 1.5, text: "fixture speech reaches provider", confidence: 0.99)]
        }
    }

    func testBrokerCompleteSnapshotIsNotTruncatedAndFailsClosed() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-broker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("container.bin")
        let payload = Data(repeating: 0x5A, count: 9 * 1024 * 1024)
        try payload.write(to: file)

        let broker = SourceBroker(maxReadBytes: 1024, maxSnapshotBytes: 10 * 1024 * 1024)
        var streamed = 0
        try broker.streamCompleteSnapshot(file.path, maxBytes: 10 * 1024 * 1024) { data, last in
            if !last { streamed += data.count }
        }
        XCTAssertEqual(streamed, payload.count)
        XCTAssertThrowsError(try broker.streamCompleteSnapshot(file.path, maxBytes: 8 * 1024 * 1024) { _, _ in }) { error in
            guard case BrokerError.snapshotTooLarge = error else { return XCTFail("unexpected error: \(error)") }
        }
    }

    func testFixtureDecodesPCMPersistsTranscriptAndSearchesIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("speech.wav")
        try Self.makeWAV(seconds: 2).write(to: media)

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog()
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)
        XCTAssertTrue(try indexer.indexOne(path: media.path))

        XCTAssertFalse(provider.received.isEmpty)
        XCTAssertTrue(provider.received.allSatisfy { $0.channels == 1 && $0.sampleRate == 16_000 })
        XCTAssertEqual(provider.received.first?.startTime, 0)
        XCTAssertTrue(provider.received.allSatisfy { $0.samples.count <= 15 * 16_000 })
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        let transcript = try catalog.transcripts(forFile: row.id)
        XCTAssertEqual(transcript.map(\.text), ["fixture speech reaches provider"])
        XCTAssertEqual(transcript.first?.provider, "fixture-provider")
        XCTAssertTrue(try catalog.searchExact("fixture").contains { $0.fileID == row.id })

        // Incremental identity/version gating must prevent a second decode/ASR.
        provider.reset()
        XCTAssertFalse(try indexer.indexOne(path: media.path))
        XCTAssertTrue(provider.received.isEmpty)
    }

    func testWhisperBackendPreflightReportsMissingLocalModel() {
        let result = WhisperCLITranscriptionProvider.preflight(
            executablePath: "/opt/homebrew/bin/whisper-cli",
            modelPath: "/private/tmp/no-such-local-whisper-model.bin")
        guard case .unavailable(let reason) = result else { return XCTFail("missing model was not fail-closed") }
        XCTAssertTrue(reason.contains("model unavailable"))
    }

    func testProvisionedWhisperBackendIndexesRealSpeech() throws {
        let whisperPath = Self.firstAvailablePath([
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ], executable: true)
        let sayPath = Self.firstAvailablePath(["/usr/bin/say"], executable: true)
        let modelPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AI Audio/Models/ggml-base.en.bin").path
        guard let whisperPath, let sayPath,
              FileManager.default.isReadableFile(atPath: modelPath) else {
            throw XCTSkip("local whisper.cpp executable, macOS say, and ggml-base.en.bin are required")
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-whisper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("spoken.aiff")
        try Self.renderSpeech("Private librarian keeps every original file read only", with: sayPath, to: media)

        let catalog = try TestSupport.makeCatalog()
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let provider = WhisperCLITranscriptionProvider(executablePath: whisperPath, modelPath: modelPath)
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        let transcript = try catalog.transcripts(forFile: row.id)
        let text = transcript.map(\.text).joined(separator: " ").lowercased()
        XCTAssertFalse(transcript.isEmpty)
        XCTAssertEqual(Set(transcript.map(\.provider)), Set([provider.providerID]))
        XCTAssertTrue(text.contains("private"), "unexpected local ASR transcript: \(text)")
        XCTAssertTrue(try catalog.searchExact("private").contains { $0.fileID == row.id })
    }

    private static func makeWAV(seconds: Int) -> Data {
        let sampleRate = 16_000
        let count = sampleRate * seconds
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let sample = Int16(sin(Double(i) * 2.0 * .pi * 440.0 / Double(sampleRate)) * 8_000).littleEndian
            withUnsafeBytes(of: sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(36 + pcm.count)); wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2)); appendLE(UInt16(2)); appendLE(UInt16(16))
        wav.append(contentsOf: Data("data".utf8)); appendLE(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }

    private static func firstAvailablePath(_ paths: [String], executable: Bool) -> String? {
        paths.first { path in
            executable ? FileManager.default.isExecutableFile(atPath: path) : FileManager.default.isReadableFile(atPath: path)
        }
    }

    private static func renderSpeech(_ phrase: String, with executablePath: String, to output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["-o", output.path, phrase]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
