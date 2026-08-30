import Foundation

/// Cheap deterministic semantic routing for source-heavy libraries. The goal is
/// not to summarize code with an LLM; it is to avoid creating millions of
/// redundant overlapping vectors for compiler/browser checkouts while keeping
/// enough authored context for useful project search.
public enum SemanticCompaction {
    public enum Strategy: Sendable, Equatable {
        case skip
        case single(String)
        case prose(primary: String, chunks: [String])
    }

    public static let maxPrimaryCharacters = 4_000
    public static let maxProseChunks = 6

    private static let sourceExtensions: Set<String> = [
        "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "m", "mm",
        "swift", "rs", "go", "java", "kt", "kts", "scala", "cs", "fs", "fsx",
        "py", "pyx", "rb", "php", "js", "jsx", "ts", "tsx", "mjs", "cjs",
        "sh", "bash", "zsh", "fish", "ps1", "lua", "r", "jl", "dart",
        "ex", "exs", "erl", "hrl", "clj", "cljs", "cljc", "hs", "lhs",
        "ml", "mli", "sol", "proto", "graphql", "gql", "sql",
        "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "astro",
        "cmake", "gn", "gni", "bzl"
    ]

    private static let sourceLikeNames: Set<String> = [
        "makefile", "dockerfile", "podfile", "gemfile", "rakefile",
        "package.swift", "build.gradle", "build.gradle.kts", "settings.gradle",
        "settings.gradle.kts", "cmakelists.txt", "meson.build", "build.ninja"
    ]

    private static let skipNames: Set<String> = [
        "package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock",
        "cargo.lock", "podfile.lock", "composer.lock", "gemfile.lock"
    ]

    public static func strategy(path: String, text: String) -> Strategy {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skip }

        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (path as NSString).pathExtension.lowercased()
        if skipNames.contains(name)
            || ext == "map"
            || name.hasSuffix(".min.js")
            || name.hasSuffix(".min.css") {
            return .skip
        }

        if sourceExtensions.contains(ext) || sourceLikeNames.contains(name) {
            return .single(compactSource(path: path, text: trimmed))
        }

        let primary = boundedPrimary(trimmed)
        let chunks = Array(LocalModelBridge.textChunks(trimmed).prefix(maxProseChunks))
        return .prose(primary: primary, chunks: chunks)
    }

    private static func boundedPrimary(_ text: String) -> String {
        String(text.prefix(maxPrimaryCharacters))
    }

    /// Preserve filename, leading context, declaration-ish lines, and the tail.
    /// This is deliberately lexical and fast: no parser, model, or repository
    /// walk is needed merely to create the one code embedding.
    private static func compactSource(path: String, text: String) -> String {
        let filename = (path as NSString).lastPathComponent
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let declarationPrefixes = [
            "class ", "struct ", "enum ", "protocol ", "extension ", "func ",
            "interface ", "record ", "def ", "async def ", "fn ", "trait ",
            "impl ", "function ", "export ", "import ", "package ", "module "
        ]
        var declarations: [String] = []
        var declarationCharacters = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            guard declarationPrefixes.contains(where: { lower.hasPrefix($0) }) else { continue }
            let clipped = String(line.prefix(220))
            guard declarationCharacters + clipped.count <= 1_000 else { break }
            declarations.append(clipped)
            declarationCharacters += clipped.count + 1
        }

        let head = String(text.prefix(2_400))
        let tailCount = min(800, text.count)
        let tailStart = text.index(text.endIndex, offsetBy: -tailCount)
        let tail = String(text[tailStart...])
        let declarationBlock = declarations.joined(separator: "\n")
        let capsule = """
        file: \(filename)
        head:
        \(head)
        declarations:
        \(declarationBlock)
        tail:
        \(tail)
        """
        return String(capsule.prefix(maxPrimaryCharacters))
    }
}
