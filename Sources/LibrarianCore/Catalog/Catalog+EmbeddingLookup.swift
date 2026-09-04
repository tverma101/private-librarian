import Foundation

extension Catalog {
    /// Cheap existence probe used by scan-time prefetch. It intentionally does
    /// not load the vector blob: unchanged files that already have the current
    /// provider's image embedding must remain zero-inference rescans.
    public func hasEmbedding(fileID: String, model: String) throws -> Bool {
        try query(
            "SELECT 1 FROM embeddings WHERE file_id=? AND model=? LIMIT 1",
            binds: [.text(fileID), .text(model)]
        ) { _ in true }.first == true
    }
}
