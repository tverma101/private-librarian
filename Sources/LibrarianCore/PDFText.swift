import Foundation
import PDFKit

/// PDFKit-based text extraction (plan §7). Read-only: PDFDocument is opened
/// from the data the broker already read (bounded), never via write-capable
/// URLs. OCR fallback is intentionally NOT in v1 core; low-text PDFs are
/// marked for review instead of invoking heavier machinery.
public enum PDFText {

    /// Extract text from a PDF using bounded reads through the broker.
    /// Returns nil when the file isn't a parseable PDF.
    public static func extract(path: String, broker: SourceBroker, maxBytes: Int64 = 64 * 1024 * 1024) -> String? {
        guard let data = try? broker.boundedRead(path, limit: maxBytes) else { return nil }
        guard let doc = PDFDocument(data: data) else { return nil }
        var out = ""
        let pageCount = min(doc.pageCount, 2_000)
        for i in 0..<pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let s = page.string {
                out += s
                out += "\n"
            }
            if out.count > 400_000 { break }
        }
        return out.isEmpty ? nil : out
    }

    /// Fraction of extractable text — used to decide "scanned PDF needs review".
    public static func textDensity(_ text: String?, pdfBytes: Int64) -> Double {
        guard let text, pdfBytes > 0 else { return 0 }
        return Double(text.utf8.count) / Double(pdfBytes)
    }
}
