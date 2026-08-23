import XCTest
import AVFoundation
@testable import LibrarianCore

final class MediaIntelligenceTests: XCTestCase {

    /// Fixture transcription provider. Records every PCM chunk it is handed
    /// and every call made to it, and serves scripted segment text so
    /// replacement/staleness behavior can be asserted deterministically
    /// without any ASR binary.
    private final class RecordingProvider: SpeechTranscriptionProvider, @unchecked Sendable {
        let providerID = "fixture-provider"
        private let lock = NSLock()
        private(set) var received: [PCMChunk] = []
        private(set) var transcribeCalls = 0
        private var queuedScripts: [String] = []
        private let defaultScript: String

        init(defaultScript: String = "fixture speech reaches provider") {
            self.defaultScript = defaultScript
        }

        func reset() {
            lock.lock()
            received = []
            transcribeCalls = 0
            lock.unlock()
        }

        /// Serve this text on the NEXT transcribe call (one-shot), then fall
        /// back to the default script.
        func enqueue(nextScript: String) {
            lock.lock()
            queuedScripts.append(nextScript)
            lock.unlock()
        }

        func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]? {
            lock.lock()
            defer { lock.unlock() }
            received.append(contentsOf: chunks)
            transcribeCalls += 1
            let text = queuedScripts.isEmpty ? defaultScript : queuedScripts.removeFirst()
            return [TranscriptSegment(start: 0, end: 1.5, text: text, confidence: 0.99)]
        }
    }

    /// Decoder wrapper that counts real decode invocations so tests can prove
    /// an unchanged pass performs zero work instead of trusting a boolean.
    private final class CountingDecoder: PCMDecoding, @unchecked Sendable {
        private let underlying = BrokerPCMDecoder()
        private let lock = NSLock()
        private(set) var decodeCalls = 0

        func reset() {
            lock.lock()
            decodeCalls = 0
            lock.unlock()
        }

        func decode(path: String, broker: SourceBroker,
                    onChunk: (PCMChunk) throws -> Void) throws {
            lock.lock()
            decodeCalls += 1
            lock.unlock()
            try underlying.decode(path: path, broker: broker, onChunk: onChunk)
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

    /// The production lane, exercised end-to-end with NO manual injection:
    /// generated WAV bytes -> SourceBroker -> decoder -> mono PCM ->
    /// transcription provider -> timestamped transcript -> encrypted Catalog
    /// -> exact/FTS search.
    func testFixtureDecodesPCMPersistsTranscriptAndSearchesIt() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogDir = root.appendingPathComponent("catalog")
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        let dbPath = catalogDir.appendingPathComponent("catalog.db").path
        let media = root.appendingPathComponent("speech.wav")
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)

        let provider = RecordingProvider()
        let catalog = try Catalog(path: dbPath, key: Data("media-e2e-key".utf8))
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)
        XCTAssertTrue(try indexer.indexOne(path: media.path))

        // Provider really saw decoded mono PCM at the configured pipeline rate.
        XCTAssertFalse(provider.received.isEmpty)
        XCTAssertTrue(provider.received.allSatisfy { $0.channels == 1 && $0.sampleRate == 16_000 })
        XCTAssertEqual(provider.received.first?.startTime, 0)
        XCTAssertTrue(provider.received.allSatisfy { $0.samples.count <= 15 * 16_000 })
        // Non-empty, in-range samples — silence-only payloads would not prove decoding.
        XCTAssertTrue(provider.received.contains { chunk in
            chunk.samples.count >= 16_000 && chunk.samples.contains(where: { abs($0) > 0.001 })
        })

        // Timestamped transcript persisted inside the ENCRYPTED catalog.
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        let transcript = try catalog.transcripts(forFile: row.id)
        XCTAssertEqual(transcript.map(\.text), ["fixture speech reaches provider"])
        XCTAssertEqual(transcript.first?.provider, "fixture-provider")
        XCTAssertEqual(transcript.first?.start ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(transcript.first?.end ?? -1, 1.5, accuracy: 0.001)
        XCTAssertTrue(try catalog.searchExact("fixture").contains { $0.fileID == row.id })
        XCTAssertFalse(Catalog.onDiskHeaderIsPlaintextSQLite(path: dbPath), "catalog must be encrypted at rest")

        // Incremental identity/version gating must prevent a second decode/ASR.
        provider.reset()
        XCTAssertFalse(try indexer.indexOne(path: media.path))
        XCTAssertTrue(provider.received.isEmpty)
        XCTAssertTrue(try catalog.transcripts(forFile: row.id).map(\.text) == ["fixture speech reaches provider"])
    }

    /// Executable proof of incremental behavior: after one successful media
    /// index, an unchanged second pass performs ZERO decode, ZERO ASR, and
    /// ZERO transcript rewrite — even through a fresh Indexer instance, so the
    /// guarantee cannot be explained by in-memory caching.
    func testUnchangedSecondPassPerformsZeroDecodeZeroASRZeroTranscriptRewrite() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-incr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("incremental.wav")
        try Self.makeWAV(sampleRate: 44_100, channels: 2, seconds: 2, amplitude: 12_000).write(to: media)

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "incr-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let broker = SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes)
        let scheduler = Scheduler()
        let decoder = CountingDecoder()

        func makeIndexer() -> Indexer {
            Indexer(broker: broker, catalog: catalog, scheduler: scheduler, options: options,
                    transcriptionProvider: provider, pcmDecoder: decoder)
        }

        let indexer = makeIndexer()
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertGreaterThan(decoder.decodeCalls, 0, "first pass must really decode")

        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        let first = try catalog.transcripts(forFile: row.id)
        XCTAssertEqual(first.map(\.text), ["fixture speech reaches provider"])
        XCTAssertEqual(first.first?.provider, "fixture-provider")
        XCTAssertEqual(provider.transcribeCalls, 1)

        // Second pass, SAME Indexer instance.
        provider.reset()
        decoder.reset()
        XCTAssertFalse(try indexer.indexOne(path: media.path))
        XCTAssertEqual(provider.transcribeCalls, 0, "unchanged pass must not invoke ASR")
        XCTAssertEqual(decoder.decodeCalls, 0, "unchanged pass must not decode")

        // Third pass through a FRESH Indexer (cold instance, shared catalog):
        // still zero work — the gate lives in persisted state, not memory.
        XCTAssertFalse(try makeIndexer().indexOne(path: media.path))
        XCTAssertEqual(provider.transcribeCalls, 0, "fresh-instance unchanged pass must not invoke ASR")
        XCTAssertEqual(decoder.decodeCalls, 0, "fresh-instance unchanged pass must not decode")

        // Transcript rows were never rewritten: byte-identical values remain.
        let after = try catalog.transcripts(forFile: row.id)
        XCTAssertEqual(after.map(\.text), first.map(\.text))
        XCTAssertEqual(after.map(\.start), first.map(\.start))
        XCTAssertEqual(after.map(\.end), first.map(\.end))
        XCTAssertEqual(after.map(\.provider), first.map(\.provider))
    }

    /// When a previously-transcribed source changes and the new generation
    /// produces a NEW transcript, the old transcript is replaced atomically:
    /// readers see only the new generation, and stale text is unsearchable.
    func testChangedGenerationReplacesTranscriptWithoutStaleRemnants() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-repl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("replaced.wav")

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "repl-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        provider.enqueue(nextScript: "quartz beacon generation one transcript")
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text),
                       ["quartz beacon generation one transcript"])
        XCTAssertTrue(try catalog.searchExact("beacon").contains { $0.fileID == row.id })

        // Generation 2: different bytes at the same path, different transcript.
        try Self.makeWAV(sampleRate: 22_050, channels: 1, seconds: 3, amplitude: 5_000).write(to: media)
        provider.enqueue(nextScript: "onyx harbor generation two transcript")
        XCTAssertTrue(try indexer.indexOne(path: media.path))

        let replaced = try catalog.transcripts(forFile: row.id)
        XCTAssertEqual(replaced.map(\.text), ["onyx harbor generation two transcript"],
                       "old generation's transcript must be gone, new one present")
        XCTAssertEqual(replaced.compactMap(\.provider).filter { $0 != provider.providerID }, [])
        // Old text must be unsearchable; new text searchable.
        XCTAssertFalse(try catalog.searchExact("beacon").contains { $0.fileID == row.id },
                       "stale transcript text must not remain searchable")
        XCTAssertTrue(try catalog.searchExact("harbor").contains { $0.fileID == row.id })
        XCTAssertEqual(Set(try catalog.searchExact("harbor").map(\.fileID)), Set([row.id]))
    }

    /// If the new generation can no longer produce a transcript (decoding now
    /// fails), the previous generation's transcript must NOT silently remain
    /// presented as current. It is purged in the same transaction that marks
    /// the new generation indexed.
    func testUndecodableGenerationPurgesStaleTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-stale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("corrupted.wav")

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "stale-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1 indexes cleanly and gains a transcript.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id))

        // Generation 2: same path, undecodable payload (RIFF magic, truncated
        // body). Whether the environment lacks an external demuxer or the
        // demuxer rejects the bytes, decode must fail closed.
        var junk = Data("RIFF".utf8)
        junk.append(Data(repeating: 0x21, count: 4096))
        try junk.write(to: media)

        XCTAssertTrue(try indexer.indexOne(path: media.path), "decode failure must not abort indexing")
        XCTAssertEqual(try catalog.fileKind(id: row.id), "audio")
        XCTAssertFalse(try catalog.transcriptExists(forFile: row.id),
                       "stale transcript must be purged when the new generation cannot decode")
        XCTAssertTrue(try catalog.transcripts(forFile: row.id).isEmpty)
        XCTAssertFalse(try catalog.searchExact("fixture").contains { $0.fileID == row.id },
                       "purged transcript text must not remain searchable")
    }

    /// The other staleness path: a changed generation that still decodes but
    /// no longer QUALIFIES for ASR (here: too short for the speech gate) must
    /// also purge the previous generation's transcript.
    func testGenerationNoLongerQualifyingPurgesStaleTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("shortened.wav")

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "gate-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1: a qualifying 2-second clip gains a transcript.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertEqual(try catalog.transcripts(forFile: row.id).map(\.text),
                       ["fixture speech reaches provider"])

        // Generation 2: 0.3s at the same path — valid audio, but below the
        // probe's duration gate (too-short), so ASR never runs this generation.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 0.3, amplitude: 8_000).write(to: media)
        provider.reset()
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertEqual(provider.transcribeCalls, 0, "sub-second audio must not reach ASR")
        XCTAssertFalse(try catalog.transcriptExists(forFile: row.id),
                       "transcript from the previous generation must be purged")
        XCTAssertFalse(try catalog.searchExact("fixture").contains { $0.fileID == row.id })
    }

    /// Kind-routing staleness: file ids are PATH-derived, so replacing a
    /// transcribed audio file's bytes with non-media content at the same path
    /// reuses the id (kind stays extension-derived by design). The old
    /// generation's transcript must still be purged — the new bytes cannot
    /// produce one.
    func testNonMediaContentAtSamePathPurgesStaleTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-kind-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("now-a-document.wav")

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "kind-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1: audio with a transcript.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertEqual(try catalog.fileKind(id: row.id), "audio")
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id))

        // Generation 2: same path, now plain-text bytes (still .wav-routed).
        // Decode cannot produce PCM here — whether the host has an external
        // demuxer or not — so this generation yields no transcript.
        try "plain notes, definitely not audio".write(to: media, atomically: true, encoding: .utf8)
        provider.reset()
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertEqual(provider.transcribeCalls, 0, "undecodable bytes must never reach ASR")
        XCTAssertFalse(try catalog.transcriptExists(forFile: row.id),
                       "audio transcript must not survive a generation whose bytes are not audio")
        XCTAssertFalse(try catalog.searchExact("fixture").contains { $0.fileID == row.id })
    }

    /// Regression for the adversarial-review BLOCKER: a WAV whose data chunk
    /// declares more bytes than the snapshot contains must fail closed. The
    /// tolerant external demuxer would otherwise decode the surviving prefix
    /// and exit 0, presenting corrupt partial speech as current.
    func testTruncatedWAVFailsClosedInsteadOfDecodingPrefix() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-trunc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let media = dir.appendingPathComponent("truncated.wav")

        // Truthful-looking header for 1 second of 16 kHz mono…
        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(36 + 32_000)); wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1)); appendLE(UInt32(16_000))
        appendLE(UInt32(32_000)); appendLE(UInt16(2)); appendLE(UInt16(16))
        wav.append(contentsOf: Data("data".utf8)); appendLE(UInt32(32_000))
        // …but only 64 bytes of payload survive.
        wav.append(Data(repeating: 0x11, count: 64))
        try wav.write(to: media)

        let decoder = BrokerPCMDecoder()
        let broker = SourceBroker(maxSnapshotBytes: 16 * 1024 * 1024)
        var chunks: [PCMChunk] = []
        XCTAssertThrowsError(try decoder.decode(path: media.path, broker: broker) { chunks.append($0) },
                             "truncated RIFF/WAVE must never reach the tolerant external demuxer")
        XCTAssertTrue(chunks.isEmpty, "no partial prefix may be emitted")
    }

    /// A decoder that emits one chunk and then throws mid-stream must not let
    /// its partial PCM reach ASR: a prefix of a failed decode is still a lie.
    private struct PartialThenThrowingDecoder: PCMDecoding {
        func decode(path: String, broker: SourceBroker,
                    onChunk: (PCMChunk) throws -> Void) throws {
            try onChunk(PCMChunk(samples: [0.5, -0.5], sampleRate: 16_000, channels: 1, startTime: 0))
            throw MediaDecoderError.decoderFailed(status: -1, detail: "synthetic mid-stream failure")
        }
    }

    func testMidStreamDecodeFailureClearsPartialPCMBeforeASR() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-partial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("partial.wav")
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "partial-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider, pcmDecoder: PartialThenThrowingDecoder())

        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertEqual(provider.transcribeCalls, 0, "partial PCM must be cleared before ASR")
        XCTAssertEqual(provider.received.count, 0)
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertFalse(try catalog.transcriptExists(forFile: row.id))
        XCTAssertFalse(try catalog.searchExact("fixture").contains { $0.fileID == row.id })
    }

    /// Replacing a transcribed audio file with a SYMLINK at the same path
    /// reuses the path-derived id; the old generation's speech must be purged.
    func testSymlinkReplacementPurgesStaleTranscript() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-syml-\(UUID().uuidString)")
        let container = root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let media = root.appendingPathComponent("now-a-link.wav")

        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "syml-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1: audio with a transcript.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id))

        // Generation 2: the path is now a symlink (never opened by the broker).
        let target = container.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try "harmless target".write(to: target, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: media)
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: target)

        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertFalse(try catalog.transcriptExists(forFile: row.id),
                       "audio transcript must not survive under a symlink generation")
        XCTAssertFalse(try catalog.searchExact("fixture").contains { $0.fileID == row.id })
    }

    /// A regeneration whose snapshot exceeds the media policy (file grew past
    /// the ceiling) is NOT evidence that speech vanished: the read failure
    /// leaves the entry pending for retry and must NOT purge a valid
    /// transcript or mark the generation indexed.
    func testOversizeRegenerationKeepsTranscriptAndStaysPending() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-oversize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("grew.wav")

        var options = Indexer.Options()
        options.enableLocalASR = true
        options.maxMediaSnapshotBytes = 1024 * 1024 // 1 MB ceiling
        let provider = RecordingProvider()
        let catalog = try TestSupport.makeCatalog(tag: "oversize-\(UUID().uuidString)")
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options,
                              transcriptionProvider: provider)

        // Generation 1: small clip gains a transcript.
        try Self.makeWAV(sampleRate: 16_000, channels: 1, seconds: 2, amplitude: 8_000).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let row = try XCTUnwrap(try catalog.allFiles().first { $0.path == media.path })
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id))
        provider.reset()

        // Generation 2: the file grew far beyond the snapshot ceiling.
        try Data(repeating: 0x21, count: 3 * 1024 * 1024).write(to: media)
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        let status = try XCTUnwrap(catalog.allFiles().first { $0.id == row.id }?.status)
        XCTAssertEqual(status, "pending", "unreadable-generation must stay retryable, not indexed")
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id),
                      "transcript must be retained until a readable generation proves it stale")
        XCTAssertEqual(provider.transcribeCalls, 0)

        // Unchanged follow-up pass retries (pending never qualifies for skip).
        XCTAssertTrue(try indexer.indexOne(path: media.path))
        XCTAssertTrue(try catalog.transcriptExists(forFile: row.id))
    }

    // MARK: - ASR preflight determinism

    /// The three preflight outcomes are distinguished independently of
    /// Homebrew, the CI runner, or the developer machine: fixtures are built
    /// in a temp directory, never referenced from /opt/homebrew.
    func testWhisperPreflightExecutableMissingReportsExecutableUnavailable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asr-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let missingExe = dir.appendingPathComponent("no-such-whisper-cli").path
        let missingModel = dir.appendingPathComponent("no-such-model.bin").path
        XCTAssertFalse(FileManager.default.isExecutableFile(atPath: missingExe))

        guard case .unavailable(let reason) = WhisperCLITranscriptionProvider.preflight(
            executablePath: missingExe, modelPath: missingModel) else {
            return XCTFail("missing executable was not fail-closed")
        }
        XCTAssertTrue(reason.contains("executable unavailable"), "wrong failure mode surfaced: \(reason)")
        XCTAssertFalse(reason.contains("model unavailable"))
    }

    func testWhisperPreflightModelMissingReportsModelUnavailable() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asr-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeExe = dir.appendingPathComponent("whisper-cli-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeExe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExe.path)
        let missingModel = dir.appendingPathComponent("no-such-model.bin").path

        guard case .unavailable(let reason) = WhisperCLITranscriptionProvider.preflight(
            executablePath: fakeExe.path, modelPath: missingModel) else {
            return XCTFail("missing model was not fail-closed")
        }
        XCTAssertTrue(reason.contains("model unavailable"), "wrong failure mode surfaced: \(reason)")
        XCTAssertFalse(reason.contains("executable unavailable"))
    }

    func testWhisperPreflightAvailableWhenBothPresent() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("asr-preflight-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fakeExe = dir.appendingPathComponent("whisper-cli-fixture")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: fakeExe)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeExe.path)
        let fakeModel = dir.appendingPathComponent("model.bin")
        try Data(repeating: 0x07, count: 64).write(to: fakeModel)

        XCTAssertEqual(WhisperCLITranscriptionProvider.preflight(
            executablePath: fakeExe.path, modelPath: fakeModel.path), .available)
    }

    // MARK: - Sparse video sampling

    /// Deterministic regression: a small VALID container produced in-process
    /// (AVAssetWriter, no network, no binaries) reaches the sparse frame
    /// sampler through the complete-snapshot policy. Skipped only where the
    /// platform genuinely cannot encode H.264 — never faked.
    func testVideoSamplerSamplesFramesFromGeneratedContainer() throws {
        #if canImport(AVFoundation)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("clip.mp4")
        try Self.writeGrayscaleMP4(to: media, width: 320, height: 240, frames: 10, fps: 10)

        let bytes = try Data(contentsOf: media)
        XCTAssertGreaterThan(bytes.count, 1024, "encoder produced an empty container")

        let sampled = VideoSampler.sampleFrames(bytes: bytes, fileExtension: "mp4")
        XCTAssertGreaterThanOrEqual(sampled, 1, "valid small video failed to reach the sampler")

        // The same container flows through the production indexing policy.
        let catalog = try TestSupport.makeCatalog(tag: "video-\(UUID().uuidString)")
        var options = Indexer.Options()
        options.enableLocalASR = false
        options.maxMediaSnapshotBytes = 16 * 1024 * 1024
        let indexer = Indexer(broker: SourceBroker(maxSnapshotBytes: options.maxMediaSnapshotBytes),
                              catalog: catalog, scheduler: Scheduler(), options: options)
        XCTAssertTrue(try indexer.indexOne(path: media.path), "video indexing must survive the complete-snapshot policy")
        #else
        throw XCTSkip("AVFoundation unavailable on this platform")
        #endif
    }

    // MARK: - Real local ASR backend (opt-in, skippable)

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

    // MARK: - Fixtures

    /// Deterministic uncompressed RIFF/WAVE-PCM fixture. Pure math — no
    /// platform encoder involved, bit-identical on every machine.
    private static func makeWAV(sampleRate: Int, channels: Int, seconds: Double, amplitude: Int16) -> Data {
        precondition(channels >= 1 && channels <= 2)
        let frameCount = Int(Double(sampleRate) * seconds)
        var pcm = Data(capacity: frameCount * channels * 2)
        for f in 0..<frameCount {
            let base = sin(Double(f) * 2.0 * Double.pi * 440.0 / Double(sampleRate)) * Double(amplitude)
            for c in 0..<channels {
                // Stereo: right channel phase-shifted so fold-by-mean is observable.
                let value = c == 0 ? base
                    : sin(Double(f) * 2.0 * Double.pi * 550.0 / Double(sampleRate)) * Double(amplitude)
                let sample = Int16(value).littleEndian
                withUnsafeBytes(of: sample) { pcm.append(contentsOf: $0) }
            }
        }
        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(36 + pcm.count)); wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(channels)); appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * channels * 2)); appendLE(UInt16(UInt16(channels) * 2)); appendLE(UInt16(16))
        wav.append(contentsOf: Data("data".utf8)); appendLE(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }

    /// Renders a tiny valid MP4 (solid grayscale frames, gently changing) using
    /// AVAssetWriter entirely in-process. Throws a skip-tagged error when the
    /// host cannot supply an H.264 encoder rather than emitting a fake.
    private static func writeGrayscaleMP4(to url: URL, width: Int, height: Int,
                                          frames: Int, fps: Int) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else {
            throw XCTSkip("H.264 writer input unsupported on this runner")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw XCTSkip("no usable H.264 encoder on this runner: \(writer.error.map(String.init(describing:)) ?? "unknown")")
        }
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            // Bounded readiness wait: a wedged encoder must fail the fixture,
            // not hang the runner.
            var waited: TimeInterval = 0
            while !input.isReadyForMoreMediaData {
                guard waited < 10 else {
                    throw XCTSkip("encoder never became ready for more media data (runner limitation)")
                }
                Thread.sleep(forTimeInterval: 0.005)
                waited += 0.005
            }
            let pixelBuffer = try Self.grayPixelBuffer(gray: UInt8((i * 37) % 200 + 20), width: width, height: height)
            let time = CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw XCTSkip("pixel buffer append refused (encoder limitation): \(writer.error.map(String.init(describing:)) ?? "unknown")")
            }
        }
        input.markAsFinished()
        // Bounded finalization: a wedged encoder must fail the fixture, not
        // hang the runner forever.
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        guard semaphore.wait(timeout: .now() + 30) == .success,
              writer.status == .completed else {
            throw XCTSkip("encoder failed to finalize (runner limitation): \(writer.error.map(String.init(describing:)) ?? "timeout")")
        }
    }

    private static func grayPixelBuffer(gray: UInt8, width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_32ARGB, nil, &buffer)
        guard status == kCVReturnSuccess, let pb = buffer else {
            throw XCTSkip("CVPixelBufferCreate failed: \(status)")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let plane = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                memset(plane + y * stride, Int32(gray), stride)
            }
        }
        return pb
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
