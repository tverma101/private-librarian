import Foundation

/// Minimal offline CLIP BPE tokenizer for the genuine MobileCLIP Core ML
/// text encoder. The model contract is the OpenAI CLIP 77-token vocabulary;
/// vocab.json and merges.txt are read from the provisioned model directory.
///
/// The byte-to-unicode construction and BPE merge contract follow the
/// BSD-licensed `sfomuseum/swift-mobileclip` reference, but are kept local so
/// the core target has no network or package-runtime dependency.
struct MobileCLIPTokenizer: Sendable {
    private struct Pair: Hashable, Sendable {
        let left: String
        let right: String
    }

    private let vocabulary: [String: Int]
    private let ranks: [Pair: Int]
    private let byteEncoder: [UInt8: String]

    init?(modelRoots: [URL]) {
        guard let vocabURL = Self.firstFile(named: ["vocab.json", "clip-vocab.json"], roots: modelRoots),
              let mergesURL = Self.firstFile(named: ["merges.txt", "clip-merges.txt"], roots: modelRoots),
              let vocabData = try? Data(contentsOf: vocabURL),
              let vocabulary = try? JSONDecoder().decode([String: Int].self, from: vocabData),
              let mergeText = try? String(contentsOf: mergesURL, encoding: .utf8) else { return nil }

        var ranks: [Pair: Int] = [:]
        for (index, raw) in mergeText.split(whereSeparator: \.isNewline).dropFirst().enumerated() {
            let parts = raw.split(separator: " ").map(String.init)
            guard parts.count == 2 else { continue }
            ranks[Pair(left: parts[0], right: parts[1])] = index
        }
        guard vocabulary["<|startoftext|>"] != nil,
              vocabulary["<|endoftext|>"] != nil else { return nil }

        self.vocabulary = vocabulary
        self.ranks = ranks
        self.byteEncoder = Self.makeByteEncoder()
    }

    func encodeFull(_ text: String) -> [Int32] {
        let start = vocabulary["<|startoftext|>"] ?? 0
        let end = vocabulary["<|endoftext|>"] ?? 0
        let body = tokenize(text).prefix(75)
        var output = [Int32](repeating: 0, count: 77)
        output[0] = Int32(start)
        for (index, token) in body.enumerated() {
            output[index + 1] = Int32(token)
        }
        output[min(body.count + 1, 76)] = Int32(end)
        return output
    }

    private func tokenize(_ text: String) -> [Int] {
        let pattern = #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let lowered = text.lowercased()
        let range = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        return regex.matches(in: lowered, range: range).flatMap { match -> [Int] in
            guard let swiftRange = Range(match.range, in: lowered) else { return [] }
            let token = String(lowered[swiftRange])
            let encoded = token.utf8.map { byteEncoder[$0] ?? "" }.joined()
            return bpe(encoded).compactMap { vocabulary[$0] }
        }
    }

    private func bpe(_ token: String) -> [String] {
        guard !token.isEmpty else { return [] }
        var word = token.map(String.init)
        if let last = word.popLast() {
            word.append(last + "</w>")
        }
        guard word.count > 1 else { return word }

        var pairs = makePairs(word)
        while true {
            guard let best = pairs.compactMap({ pair -> (Pair, Int)? in
                guard let rank = ranks[pair] else { return nil }
                return (pair, rank)
            }).min(by: { $0.1 < $1.1 })?.0 else { break }

            var merged: [String] = []
            var index = 0
            while index < word.count {
                if index < word.count - 1,
                   word[index] == best.left,
                   word[index + 1] == best.right {
                    merged.append(best.left + best.right)
                    index += 2
                } else {
                    merged.append(word[index])
                    index += 1
                }
            }
            word = merged
            if word.count == 1 { break }
            pairs = makePairs(word)
        }
        return word
    }

    private func makePairs(_ word: [String]) -> Set<Pair> {
        guard word.count > 1 else { return [] }
        return Set(zip(word, word.dropFirst()).map { Pair(left: $0.0, right: $0.1) })
    }

    private static func firstFile(named names: [String], roots: [URL]) -> URL? {
        for root in roots {
            let candidates = [root, root.appendingPathComponent("clip-vit-base-patch32")]
            for candidate in candidates {
                for name in names {
                    let url = candidate.appendingPathComponent(name)
                    if FileManager.default.isReadableFile(atPath: url.path) { return url }
                }
            }
        }
        return nil
    }

    private static func makeByteEncoder() -> [UInt8: String] {
        let direct: [UInt8] = Array(UInt8(33)...UInt8(126))
            + Array(UInt8(161)...UInt8(172))
            + Array(UInt8(174)...UInt8(255))
        var bytes = direct
        var unicode = direct.map { Int($0) }
        var next = 256
        for value in UInt8.min...UInt8.max where !direct.contains(value) {
            bytes.append(value)
            unicode.append(next)
            next += 1
        }
        var result: [UInt8: String] = [:]
        for (byte, scalar) in zip(bytes, unicode) {
            if let u = UnicodeScalar(scalar) { result[byte] = String(Character(u)) }
        }
        return result
    }
}
