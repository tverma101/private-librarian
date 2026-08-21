import Foundation
import CryptoKit

/// Deterministic duplicate-detection engine (plan §18, §19).
/// - Size bucketing first: only files sharing an exact size are candidates.
/// - Partial fingerprint (head+middle+tail 64 KiB windows) for candidates.
/// - Full SHA-256 only within matching partial groups.
/// Never deletes anything — produces report-only verdicts.
public struct DuplicateDetector: Sendable {

    public enum Verdict: String, Codable, Sendable {
        case exactDuplicate       // full SHA-256 match
        case possibleVisualDuplicate // Vision feature-print similarity (set by caller)
        case none
    }

    public struct PartialFingerprint: Sendable, Equatable {
        public let size: Int64
        public let head: Data
        public let middle: Data
        public let tail: Data
    }

    public static let windowSize = 64 * 1024

    public init() {}

    /// Group file ids by exact byte size. Only groups with >1 member matter.
    public static func candidateGroups(sizes: [String: Int64]) -> [[String]] {
        var bySize: [Int64: [String]] = [:]
        for (id, size) in sizes { bySize[size, default: []].append(id) }
        return bySize.values.filter { $0.count > 1 }
    }

    /// Read head/middle/tail windows through the read-only broker.
    public static func partialFingerprint(path: String, size: Int64, broker: SourceBroker) throws -> PartialFingerprint {
        let w = Int64(Self.windowSize)
        func clamp(_ v: Int64) -> Int64 { min(max(v, 0), size) }

        let head = try broker.boundedRead(path, limit: w)
        let midStart = clamp(size / 2 - w / 2)
        let middle = try broker.readSlice(path: path, offset: midStart, length: min(w, size - midStart))
        let tailStart = clamp(size - w)
        let tail = try broker.readSlice(path: path, offset: tailStart, length: min(w, size - tailStart))
        return PartialFingerprint(size: size, head: head, middle: middle, tail: tail)
    }

    /// Full SHA-256 streamed in bounded chunks via the read-only fd.
    public static func sha256(path: String, broker: SourceBroker) throws -> Data {
        var hasher = SHA256()
        try broker.streamBounded(path, limit: .max) { chunk, _ in
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize())
    }
}
