import Foundation
import Vision
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(AppKit)
import AppKit
#endif

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
    /// Max image bytes to OCR in one pass (20 MB default).
    public static let maxImageBytes = 20 * 1024 * 1024

    /// Returns true when PDFKit text is missing or too sparse to be useful.
    public static func needsOCR(pdfText: String?) -> Bool {
        guard let pdfText else { return true }
        let trimmed = pdfText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.count < 50
    }

    public init() {}

    /// Recognize text from bounded image bytes. Returns nil for malformed or
    /// unsupported images; callers can safely fall back to metadata-only logic.
    public func recognize(imageData: Data, accurate: Bool = true) -> Result? {
        guard !imageData.isEmpty else { return nil }
        guard imageData.count <= Self.maxImageBytes else { return nil }

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

    /// OCR for scanned PDFs: renders up to 10 pages to thumbnails via PDFKit
    /// (broker-bytes only) and runs Vision on each page image. Returns nil
    /// when PDFKit text is already sufficient or when rendering/recognition
    /// yields no text.
    public func recognizeScannedPDF(at path: String, broker: SourceBroker, pdfText: String?) -> Result? {
        guard Self.needsOCR(pdfText: pdfText) else { return nil }
#if canImport(PDFKit) && canImport(Vision)
#if canImport(AppKit)
        // The PDF container itself is complete; maxImageBytes applies only to
        // each rendered image passed into Vision, not to the compressed PDF
        // prefix used to create the PDFDocument.
        guard let data = try? broker.completeSnapshot(path), !data.isEmpty else { return nil }
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        let pageLimit = min(doc.pageCount, 10)
        var allLines: [Line] = []
        var allTexts: [String] = []
        for i in 0..<pageLimit {
            guard let page = doc.page(at: i) else { continue }
            // thumbnail() returns NSImage non-optional on macOS
            let thumb = page.thumbnail(of: CGSize(width: 1200, height: 1200), for: .mediaBox)
            guard let tiff = thumb.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            guard let r = recognize(imageData: png) else { continue }
            allLines.append(contentsOf: r.lines)
            allTexts.append(r.text)
        }
        guard !allLines.isEmpty else { return nil }
        let text = allTexts.joined(separator: "\n")
        let mean = allLines.reduce(Float(0)) { $0 + $1.confidence } / Float(allLines.count)
        return Result(text: text, lines: allLines, meanConfidence: mean, revision: Self.revision)
#else
        return nil
#endif
#else
        return nil
#endif
    }
}
