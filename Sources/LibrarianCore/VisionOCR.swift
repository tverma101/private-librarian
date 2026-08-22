import Foundation
import Vision

/// On-device OCR over bytes already obtained through SourceBroker.
/// This type has no filesystem API and cannot mutate source files.
public struct VisionOCR: Sendable {
    public struct Line: Sendable, Equatable {
        public let text: String
        public let confidence: Float

        public init(text: String, confidence: Float) {
            self.text = text
            self.confidence = confidence
        }
    }

    public struct Result: Sendable, Equatable {
        public let text: String
        public let lines: [Line]
        public let meanConfidence: Float
        public let revision: String

        public init(text: String, lines: [Line], meanConfidence: Float, revision: String) {
            self.text = text
            self.lines = lines
            self.meanConfidence = meanConfidence
            self.revision = revision
        }
    }

    public static let revision = "vision-ocr-v1"

    public init() {}

    /// Recognize text from bounded image bytes. Returns nil for malformed or
    /// unsupported images; callers can safely fall back to metadata-only logic.
    public func recognize(imageData: Data, accurate: Bool = true) -> Result? {
        guard !imageData.isEmpty else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true

        do {
            let handler = VNImageRequestHandler(data: imageData, options: [:])
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results ?? []
        var lines: [Line] = []
        lines.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let normalized = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            lines.append(Line(text: normalized, confidence: candidate.confidence))
        }

        guard !lines.isEmpty else { return nil }
        let text = lines.map(\.text).joined(separator: "\n")
        let mean = lines.reduce(Float(0)) { $0 + $1.confidence } / Float(lines.count)
        return Result(text: text, lines: lines, meanConfidence: mean, revision: Self.revision)
    }
}
