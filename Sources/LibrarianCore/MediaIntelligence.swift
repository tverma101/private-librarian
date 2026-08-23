import Foundation

/// Decoded PCM handed to speech analysis providers. The media/model layer
/// receives samples only; it does not receive filesystem paths or bookmarks.
public struct PCMChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double
    public let channels: Int
    public let startTime: TimeInterval

    public init(samples: [Float], sampleRate: Double, channels: Int, startTime: TimeInterval) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channels = channels
        self.startTime = startTime
    }
}

public struct TranscriptSegment: Sendable, Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String
    public let confidence: Float?

    public init(start: TimeInterval, end: TimeInterval, text: String, confidence: Float? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}

public enum SpeechLikelihood: String, Sendable {
    case unlikely
    case possible
    case likely
}

/// Swappable local ASR contract. Implementations consume decoded PCM only and
/// therefore cannot independently reopen or mutate source files.
public protocol SpeechTranscriptionProvider: Sendable {
    var providerID: String { get }
    func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]?
}

/// Tier-1/default implementation. Keeps the media lane inert until a local ASR
/// provider is explicitly enabled and benchmarked.
public struct DisabledSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    public let providerID = "disabled"
    public init() {}
    public func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]? { nil }
}

/// Local whisper.cpp CLI adapter. The provider is intentionally opt-in and
/// fails closed when either the executable or a pre-provisioned model is
/// absent. It receives only PCM chunks; the temporary WAV path is an adapter
/// implementation detail and never the indexed source path.
public struct WhisperCLITranscriptionProvider: SpeechTranscriptionProvider {
    public let providerID = "whisper.cpp-cli"
    public let executablePath: String
    public let modelPath: String

    public init(executablePath: String = "/opt/homebrew/bin/whisper-cli", modelPath: String) {
        self.executablePath = executablePath
        self.modelPath = modelPath
    }

    public enum Preflight: Sendable, Equatable {
        case available
        case unavailable(String)
    }

    public static func preflight(executablePath: String = "/opt/homebrew/bin/whisper-cli",
                                 modelPath: String) -> Preflight {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            return .unavailable("ASR executable unavailable: \(executablePath)")
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            return .unavailable("ASR model unavailable: \(modelPath)")
        }
        return .available
    }

    public func transcribe(_ chunks: [PCMChunk]) -> [TranscriptSegment]? {
        guard !chunks.isEmpty,
              case .available = Self.preflight(executablePath: executablePath, modelPath: modelPath),
              let wav = try? Self.makeWAV(chunks: chunks) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("librarian-asr-\(UUID().uuidString)")
        let input = dir.appendingPathComponent("input.wav")
        let outputBase = dir.appendingPathComponent("result")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            try wav.write(to: input, options: .atomic)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-m", modelPath, "-f", input.path, "-oj", "-of", outputBase.path,
                                 "-np", "-l", "en"]
            let errorPipe = Pipe()
            process.standardError = errorPipe
            process.standardOutput = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let jsonURL = outputBase.appendingPathExtension("json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rows = object["transcription"] as? [[String: Any]] else { return nil }
            return rows.compactMap { row in
                let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let timestamps = row["timestamps"] as? [String: Any]
                let offsets = row["offsets"] as? [String: Any]
                let start = Self.timestamp(timestamps?["from"] as? String) ??
                    (offsets?["from"] as? NSNumber).map { $0.doubleValue / 1000.0 } ?? 0
                let end = Self.timestamp(timestamps?["to"] as? String) ??
                    (offsets?["to"] as? NSNumber).map { $0.doubleValue / 1000.0 } ?? start
                return TranscriptSegment(start: start, end: max(start, end), text: text)
            }
        } catch {
            return nil
        }
    }

    private static func timestamp(_ value: String?) -> TimeInterval? {
        guard let value else { return nil }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func makeWAV(chunks: [PCMChunk]) throws -> Data {
        guard let first = chunks.first, first.sampleRate > 0, first.channels == 1,
              chunks.allSatisfy({ $0.sampleRate == first.sampleRate && $0.channels == 1 }) else {
            throw MediaDecoderError.invalidConfiguration
        }
        var pcm = Data()
        for chunk in chunks {
            for sample in chunk.samples {
                let value = Int16(max(-1, min(1, sample)) * 32767).littleEndian
                withUnsafeBytes(of: value) { pcm.append(contentsOf: $0) }
            }
        }
        var wav = Data("RIFF".utf8)
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { wav.append(contentsOf: $0) }
        }
        appendLE(UInt32(36 + pcm.count)); wav.append(contentsOf: Data("WAVEfmt ".utf8))
        appendLE(UInt32(16)); appendLE(UInt16(1)); appendLE(UInt16(1))
        appendLE(UInt32(first.sampleRate)); appendLE(UInt32(first.sampleRate * 2))
        appendLE(UInt16(2)); appendLE(UInt16(16)); wav.append(contentsOf: Data("data".utf8))
        appendLE(UInt32(pcm.count)); wav.append(pcm)
        return wav
    }
}

/// Cheap gating result produced before expensive ASR. Future AVFoundation-based
/// probing can populate this from bounded metadata/audio samples while keeping
/// the original file under SourceBroker authority.
public struct MediaAnalysisDecision: Sendable, Equatable {
    public let speechLikelihood: SpeechLikelihood
    public let shouldTranscribe: Bool
    public let reasonCodes: [String]

    public init(speechLikelihood: SpeechLikelihood, shouldTranscribe: Bool, reasonCodes: [String]) {
        self.speechLikelihood = speechLikelihood
        self.shouldTranscribe = shouldTranscribe
        self.reasonCodes = reasonCodes
    }
}

#if canImport(AVFoundation)
import AVFoundation
#endif

// MARK: - AudioProbe

/// Cheap gating probe. Operates on bytes only (never reopens original path).
/// When AVFoundation is available, duration is probed via a temp AVURLAsset;
/// otherwise falls back to extension/magic + size heuristics.
public struct AudioProbe: Sendable {

    private static let audioExtensions: Set<String> = [
        "m4a","mp3","wav","flac","aac","ogg","aiff","aif","wma","opus","alac","caf","mp2","m4r",
    ]
    private static let videoExtensions: Set<String> = [
        "mp4","mov","m4v","avi","mkv","webm","wmv","flv","m2ts","mts","3gp","hevc",
    ]
    private static let musicTagHints = ["music","song","album","track","artist"]

    /// Probe bytes for speech gating. Does not reopen the original path — when
    /// AVFoundation is available, writes bytes to a temporary probe file and
    /// uses AVURLAsset to obtain duration, then deletes immediately.
    public static func probe(bytes: Data, fileExtension extHint: String? = nil, tagHint: String? = nil) -> MediaAnalysisDecision {
        let ext = (extHint ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let isAudioExt = !ext.isEmpty && audioExtensions.contains(ext)
        let isVideoExt = !ext.isEmpty && videoExtensions.contains(ext)
        let isMediaContainer = isAudioExt || isVideoExt

        // Non-media container: unlikely
        if !isMediaContainer {
            // Also check magic signatures for common audio containers
            if !looksLikeAudioMagic(bytes) {
                return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:non-media-container"])
            }
        }

        // Check for obviously-music tags
        let tagLower = (tagHint ?? "").lowercased()
        let isMusicTagged = musicTagHints.contains(where: { tagLower.contains($0) })

        // Try AVFoundation duration probe if available
        var duration: TimeInterval? = nil
#if canImport(AVFoundation)
        duration = probeDurationViaAVFoundation(bytes: bytes, ext: ext)
#endif
        // Fallback: estimate duration from bytes if no AVFoundation
        if duration == nil || duration! <= 0 {
            // Very rough: assume 16kbps minimum → duration ≈ bytes*8 / 16000
            // Only used to reject extremes; not for precise gating
            if bytes.isEmpty {
                return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:empty"])
            }
        }

        if let d = duration, d > 0 {
            if d < 1.0 {
                return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:too-short", String(format: "duration:%.2f", d)])
            }
            if d > 7200 {
                return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:too-long", String(format: "duration:%.1f", d)])
            }
            if isMusicTagged {
                return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:music-tag", String(format: "duration:%.1f", d)])
            }
            return MediaAnalysisDecision(speechLikelihood: .possible, shouldTranscribe: true, reasonCodes: ["probe:av-duration", String(format: "duration:%.1f", d)])
        }

        // No duration available — use container/size gating
        if isMusicTagged {
            return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:music-tag-no-duration"])
        }
        if isMediaContainer && bytes.count >= 1024 {
            return MediaAnalysisDecision(speechLikelihood: .possible, shouldTranscribe: true, reasonCodes: ["probe:container-gate"])
        }
        return MediaAnalysisDecision(speechLikelihood: .unlikely, shouldTranscribe: false, reasonCodes: ["probe:unknown-container"])
    }

    private static func looksLikeAudioMagic(_ bytes: Data) -> Bool {
        guard bytes.count >= 4 else { return false }
        let b = [UInt8](bytes.prefix(12))
        // MP3 sync, FLAC, Ogg, RIFF/WAVE, M4A/ftyp
        if b[0] == 0xFF && (b[1] & 0xE0) == 0xE0 { return true } // MP3 sync
        if b[0]==0x66 && b[1]==0x4C && b[2]==0x61 && b[3]==0x43 { return true } // FLAC
        if b[0]==0x4F && b[1]==0x67 && b[2]==0x67 && b[3]==0x53 { return true } // OggS
        if b[0]==0x52 && b[1]==0x49 && b[2]==0x46 && b[3]==0x46 { return true } // RIFF
        if bytes.count >= 8 {
            let ftyp = String(bytes: bytes[4..<min(8, bytes.count)], encoding: .ascii) ?? ""
            if ftyp == "ftyp" { return true }
        }
        if b[0]==0x49 && b[1]==0x44 && b[2]==0x33 { return true } // ID3
        return false
    }

#if canImport(AVFoundation)
    private static func probeDurationViaAVFoundation(bytes: Data, ext: String) -> TimeInterval? {
        guard !bytes.isEmpty else { return nil }
        let suffix = ext.isEmpty ? "tmp" : ext
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).\(suffix)")
        do {
            try bytes.write(to: tmpURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let asset = AVURLAsset(url: tmpURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            // Use synchronous duration property (available without async loading for local files)
            let dur = asset.duration
            if dur.isValid && !dur.isIndefinite {
                let secs = CMTimeGetSeconds(dur)
                if secs.isFinite { return secs }
            }
            // Fallback: try loading duration via synchronous wait (macOS 14+ has async; use semaphore for compat)
            // If still unknown, return nil and let container gate decide
            return nil
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return nil
        }
    }
#endif
}

// MARK: - VideoSampler

/// Sparse video frame sampler. Self-contained lane; does not decode audio.
/// Uses AVAssetImageGenerator to sample up to 3 frames (0, midpoint, near-end).
/// When AVFoundation is unavailable, returns 0 without error.
public struct VideoSampler: Sendable {

    public static let maxFrames = 3

    /// Sample sparse frames from bytes. Writes bytes to a temp file, samples via
    /// AVAssetImageGenerator, deletes immediately. Returns number of frames
    /// successfully generated (0...3). Frames are discarded (no-op for now) but
    /// the count confirms the pipeline is self-contained.
    @discardableResult
    public static func sampleFrames(bytes: Data, fileExtension extHint: String? = nil) -> Int {
#if canImport(AVFoundation)
        return sampleFramesAVFoundation(bytes: bytes, extHint: extHint)
#else
        return 0
#endif
    }

#if canImport(AVFoundation)
    private static func sampleFramesAVFoundation(bytes: Data, extHint: String?) -> Int {
        guard !bytes.isEmpty else { return 0 }
        let ext = (extHint ?? "mp4").lowercased()
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("vsample-\(UUID().uuidString).\(ext)")
        do {
            try bytes.write(to: tmpURL, options: .atomic)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let asset = AVURLAsset(url: tmpURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
            let dur = asset.duration
            guard dur.isValid, !dur.isIndefinite else { return 0 }
            let total = CMTimeGetSeconds(dur)
            guard total.isFinite, total > 0 else { return 0 }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            // Cap size to avoid large allocations
            generator.maximumSize = CGSize(width: 320, height: 320)

            var times: [CMTime] = [CMTime(seconds: 0, preferredTimescale: 600)]
            if total > 0.5 {
                times.append(CMTime(seconds: total * 0.5, preferredTimescale: 600))
            }
            if total > 1.0 {
                let nearEnd = max(0, total - 0.5)
                if nearEnd > total * 0.5 + 0.1 {
                    times.append(CMTime(seconds: nearEnd, preferredTimescale: 600))
                }
            }
            // Limit to maxFrames
            times = Array(times.prefix(maxFrames))
            var count = 0
            for t in times {
                do {
                    _ = try generator.copyCGImage(at: t, actualTime: nil)
                    count += 1
                } catch {
                    continue
                }
            }
            return count
        } catch {
            try? FileManager.default.removeItem(at: tmpURL)
            return 0
        }
    }
#endif
}
