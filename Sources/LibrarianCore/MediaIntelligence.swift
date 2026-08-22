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
