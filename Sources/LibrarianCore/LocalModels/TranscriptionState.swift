import Foundation
import CryptoKit

/// A transcription attempt must say whether it produced a definitive result or
/// failed in a way that should be retried. Keeping these states separate stops
/// transient ASR failures from being committed as successful "no transcript"
/// generations.
public enum TranscriptionAttempt: Sendable, Equatable {
    case success([TranscriptSegment])
    case noTranscript
    case failure(String)
}

/// Optional richer contract for providers that can distinguish a real empty
/// result from an execution/parsing failure and can describe the exact setup
/// that affects transcript output.
public protocol StatefulSpeechTranscriptionProvider: SpeechTranscriptionProvider {
    var processingIdentity: String { get }
    func transcribeStatefully(_ chunks: [PCMChunk]) -> TranscriptionAttempt
}

/// Central adapter used by Indexer. Older/simple providers continue to work;
/// they use providerID as their incremental identity and preserve the legacy
/// optional result semantics. Production providers should implement
/// StatefulSpeechTranscriptionProvider.
public enum TranscriptionProviderState {
    public static func processingIdentity(_ provider: any SpeechTranscriptionProvider) -> String {
        if let provider = provider as? any StatefulSpeechTranscriptionProvider {
            return provider.processingIdentity
        }
        return provider.providerID
    }

    public static func transcribe(_ provider: any SpeechTranscriptionProvider,
                                  chunks: [PCMChunk]) -> TranscriptionAttempt {
        if let provider = provider as? any StatefulSpeechTranscriptionProvider {
            return provider.transcribeStatefully(chunks)
        }
        guard let segments = provider.transcribe(chunks) else { return .noTranscript }
        return segments.isEmpty ? .noTranscript : .success(segments)
    }
}

extension DisabledSpeechTranscriptionProvider: StatefulSpeechTranscriptionProvider {
    public var processingIdentity: String { "disabled" }
    public func transcribeStatefully(_ chunks: [PCMChunk]) -> TranscriptionAttempt { .noTranscript }
}

extension WhisperCLITranscriptionProvider: StatefulSpeechTranscriptionProvider {
    /// The identity contains content hashes rather than local paths. Replacing
    /// either whisper-cli or the model therefore forces exactly one honest
    /// re-index while moving the same files to another Mac does not encode a
    /// user-specific path into catalog state.
    public var processingIdentity: String {
        let executable = Self.fileFingerprint(executablePath) ?? "missing"
        let model = Self.fileFingerprint(modelPath) ?? "missing"
        return "\(providerID):exe=\(executable):model=\(model)"
    }

    public func transcribeStatefully(_ chunks: [PCMChunk]) -> TranscriptionAttempt {
        guard !chunks.isEmpty else { return .noTranscript }
        switch Self.preflight(executablePath: executablePath, modelPath: modelPath) {
        case .available:
            break
        case .unavailable(let reason):
            return .failure(reason)
        }
        guard let segments = transcribe(chunks) else {
            return .failure("ASR process failed or returned unreadable output")
        }
        return segments.isEmpty ? .noTranscript : .success(segments)
    }

    private static func fileFingerprint(_ path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
