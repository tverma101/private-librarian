import Foundation
import LibrarianCore
import CoreGraphics
import ImageIO

/// librarian-cli — verification harness for the librarian core.
/// Every subcommand is read-only with respect to source folders.
/// Catalog lives under the caller-specified path (tests use temp dirs).

let io = FileHandle.standardOutput

func printUsage() {
    let text = """
    librarian-cli — Private Local Librarian (read-only verification harness)

    USAGE:
      librarian-cli index <folder> --catalog <path> [--tier2] [--profile fast|balanced|quality] [--provider <kind>]
                                                          Index a folder into an encrypted catalog
      librarian-cli search <query> --catalog <path> [--tier2] [--profile fast|balanced|quality] [--provider <kind>]
                                                          Search inside the encrypted catalog
      librarian-cli status  --catalog <path>            Show catalog counts
      librarian-cli dupes   --catalog <path>            Compute exact duplicate groups
      librarian-cli graph-stats --catalog <path>        Measure virtual graph query size
      librarian-cli tree    --catalog <path>            Print virtual category tree
      librarian-cli provider-smoke [--samples <n>]      Measure genuine MobileCLIP image/text inference
      librarian-cli specialist-smoke --profile balanced|quality [--samples <n>]
                                                          Measure the selected SigLIP2 profile on this Mac

    PROFILE RULES:
      No profile / no --tier2  → Fast, no downloaded specialist required.
      --tier2 alone            → Balanced (compatibility with the old CLI flag).
      --profile balanced       → Balanced + Tier-2 enabled.
      --profile quality        → Quality + Tier-2 enabled.

    The GUI app owns its stable signed app-specific Keychain item. The CLI never
    opens that item; set LIBRARIAN_CATALOG_KEY to a 64-character hex key for
    headless verification.
    Source folders are opened strictly O_RDONLY|O_NOFOLLOW. Nothing is ever
    written to, moved, renamed, or deleted in the indexed folders.
    """
    print(text)
}

func argValue(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func hasFlag(_ name: String) -> Bool {
    CommandLine.arguments.contains(name)
}

func positional(_ index: Int) -> String? {
    // Drop program name AND the subcommand (args[1]); flags filtered out.
    // Values belonging to flags are still present, so callers should use this
    // only for the first positional argument, which every current command does.
    let args = CommandLine.arguments.dropFirst(2).filter { !$0.hasPrefix("--") }
    return args.count > index ? args[index] : nil
}

enum CLIError: Error, CustomStringConvertible {
    case invalidProfile(String)
    case fastHasNoSpecialist

    var description: String {
        switch self {
        case .invalidProfile(let value):
            return "unknown local-model profile '\(value)'; expected fast, balanced, or quality"
        case .fastHasNoSpecialist:
            return "Fast has no downloaded SigLIP2 specialist; use --profile balanced or --profile quality"
        }
    }
}

/// Keep the verification harness aligned with the product profile contract.
/// Historically `--tier2` meant "turn on the local model stack"; after the
/// Base-vs-So400m migration, preserve that behavior by treating a bare
/// `--tier2` as Balanced rather than silently selecting Fast/no specialist.
func requestedLocalModelProfile() throws -> LocalModelProfile {
    if let raw = argValue("--profile") {
        guard let profile = LocalModelProfile(rawValue: raw.lowercased()) else {
            throw CLIError.invalidProfile(raw)
        }
        return profile
    }
    return hasFlag("--tier2") ? .balanced : .fast
}

func tier2Enabled(for profile: LocalModelProfile) -> Bool {
    hasFlag("--tier2") || profile != .fast
}

func percentile(_ values: [Double], _ fraction: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let index = min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * fraction)) - 1))
    return sorted[index]
}

func deterministicPNG() -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.92, green: 0.08, blue: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    guard let image = context.makeImage() else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return output as Data
}

func measuredProviderResult(
    providerID: String,
    modelID: String,
    profile: String,
    expectedDimension: Int,
    preflight: EmbeddingProviderPreflight,
    imageEmbed: (Data) -> EmbeddingVector?,
    textEmbed: (String) -> EmbeddingVector?,
    samples: Int
) throws -> [String: Any] {
    if !preflight.available {
        return [
            "provider": providerID,
            "model": modelID,
            "profile": profile,
            "status": "unavailable",
            "reason": preflight.reason,
            "artifacts": preflight.artifacts,
            "dependencies": preflight.dependencies,
        ]
    }

    guard let imageBytes = deterministicPNG() else {
        throw NSError(domain: "provider-smoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not create deterministic PNG fixture"])
    }
    let query = "a red square"
    let warmCalls = max(1, samples)
    var imageLatencies: [Double] = []
    var textLatencies: [Double] = []
    var image: EmbeddingVector?
    var text: EmbeddingVector?

    let coldImageStart = Date().timeIntervalSinceReferenceDate
    image = imageEmbed(imageBytes)
    let coldImageLatency = (Date().timeIntervalSinceReferenceDate - coldImageStart) * 1000

    let coldTextStart = Date().timeIntervalSinceReferenceDate
    text = textEmbed(query)
    let coldTextLatency = (Date().timeIntervalSinceReferenceDate - coldTextStart) * 1000

    let warmImageStart = Date().timeIntervalSinceReferenceDate
    for _ in 0..<warmCalls {
        let start = Date().timeIntervalSinceReferenceDate
        image = imageEmbed(imageBytes)
        imageLatencies.append((Date().timeIntervalSinceReferenceDate - start) * 1000)
    }
    let warmImageSeconds = Date().timeIntervalSinceReferenceDate - warmImageStart

    let warmTextStart = Date().timeIntervalSinceReferenceDate
    for _ in 0..<warmCalls {
        let start = Date().timeIntervalSinceReferenceDate
        text = textEmbed(query)
        textLatencies.append((Date().timeIntervalSinceReferenceDate - start) * 1000)
    }
    let warmTextSeconds = Date().timeIntervalSinceReferenceDate - warmTextStart

    guard let image, let text,
          image.dim == expectedDimension,
          text.dim == expectedDimension,
          image.spaceID == text.spaceID,
          let cosine = LocalModelBridge.cosineSimilarity(image.data, text.data) else {
        throw NSError(domain: "provider-smoke", code: 2,
                      userInfo: [NSLocalizedDescriptionKey:
                        "provider did not produce matching \(expectedDimension)-D image/text vectors"])
    }

    let imageThroughput = warmImageSeconds > 0 ? Double(warmCalls) / warmImageSeconds : 0
    let textThroughput = warmTextSeconds > 0 ? Double(warmCalls) / warmTextSeconds : 0
    return [
        "provider": providerID,
        "model": modelID,
        "profile": profile,
        "status": "measured",
        "fixture": "deterministic-red-square-v1",
        "space_id": image.spaceID,
        "dimensions": ["image": image.dim, "text": text.dim],
        "text_to_image_cosine": cosine,
        "cold_image_latency_ms": coldImageLatency,
        "cold_text_latency_ms": coldTextLatency,
        "image_latency_ms": [
            "p50": percentile(imageLatencies, 0.50),
            "p95": percentile(imageLatencies, 0.95),
        ],
        "text_latency_ms": [
            "p50": percentile(textLatencies, 0.50),
            "p95": percentile(textLatencies, 0.95),
        ],
        "sequential_image_embeddings_per_second": imageThroughput,
        "sequential_text_embeddings_per_second": textThroughput,
        "warm_calls": warmCalls,
        "note": "Sequential warm-call baseline; not a batched throughput claim.",
    ]
}

func printJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

func runProviderSmoke(samples: Int) throws {
    let provider = CoreMLMobileCLIPProvider()
    let result = try measuredProviderResult(
        providerID: provider.providerID,
        modelID: CoreMLMobileCLIPProvider.checkpointID,
        profile: "coreml-mobileclip",
        expectedDimension: CoreMLMobileCLIPProvider.dimension,
        preflight: provider.preflight,
        imageEmbed: { provider.embedImageBytes($0) },
        textEmbed: { provider.embedJointText($0) },
        samples: samples)
    try printJSON(result)
}

func runSpecialistSmoke(profile: LocalModelProfile, samples: Int) throws {
    guard let model = LocalModelStack.semanticModel(for: profile) else {
        throw CLIError.fastHasNoSpecialist
    }
    let bridge = SpecialistModelBridge()
    let provider = SpecialistSigLIP2EmbeddingProvider(model: model, bridge: bridge)
    guard let expectedDimension = SpecialistModelBridge.siglipDimension(for: model) else {
        throw NSError(domain: "specialist-smoke", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "unknown SigLIP2 embedding dimension"])
    }
    let result = try measuredProviderResult(
        providerID: provider.providerID,
        modelID: model.id,
        profile: profile.rawValue,
        expectedDimension: expectedDimension,
        preflight: provider.preflight,
        imageEmbed: { provider.embedImageBytes($0) },
        textEmbed: { provider.embedJointText($0) },
        samples: samples)
    try printJSON(result)
}

func openCatalog(_ catalogPath: String) throws -> Catalog {
    // Headless / CI path: an explicit hex key (LIBRARIAN_CATALOG_KEY, 64 hex
    // chars = 32 bytes) bypasses the Keychain entirely so automated runs are
    // deterministic and prompt-free. Keeping the CLI on this path prevents
    // an unsigned development executable from claiming the GUI app's key.
    guard let hex = ProcessInfo.processInfo.environment["LIBRARIAN_CATALOG_KEY"] else {
        throw KeyError.missingEnvKey
    }
    let chars = Array(hex.lowercased())
    guard chars.count == 64, chars.allSatisfy({ $0.isHexDigit }) else {
        throw KeyError.badEnvKey
    }
    var bytes = [UInt8](); bytes.reserveCapacity(32)
    var i = 0
    while i < chars.count {
        bytes.append(UInt8(String(chars[i..<i + 2]), radix: 16)!)
        i += 2
    }
    return try Catalog(path: catalogPath, key: Data(bytes))
}

enum KeyError: Error, CustomStringConvertible {
    case missingEnvKey
    case badEnvKey

    var description: String {
        switch self {
        case .missingEnvKey:
            return "LIBRARIAN_CATALOG_KEY is required for CLI catalog commands; the CLI never accesses the GUI Keychain item"
        case .badEnvKey:
            return "LIBRARIAN_CATALOG_KEY must contain exactly 64 hexadecimal characters"
        }
    }
}

let args = CommandLine.arguments
guard args.count >= 2 else { printUsage(); exit(2) }

do {
    switch args[1] {
    case "index":
        guard let folder = positional(0), let catalogPath = argValue("--catalog") else {
            printUsage(); exit(2)
        }
        let profile = try requestedLocalModelProfile()
        let useTier2 = tier2Enabled(for: profile)
        let url = URL(fileURLWithPath: folder)
        // Security-scoped bookmark flow belongs to the GUI app; the CLI takes
        // an explicit path argument from the operator.
        do {
            if url.startAccessingSecurityScopedResource() {
                url.stopAccessingSecurityScopedResource()
            }
        }
        let catalog = try openCatalog(catalogPath)
        let broker = SourceBroker()
        var options = Indexer.Options()
        options.enableLocalEmbeddings = useTier2
        options.embeddingProviderKind = argValue("--provider")
        options.localModelProfile = profile
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler(), options: options)
        let t0 = Date()
        var sessionOptions = ScalableIndexSession.Options()
        sessionOptions.enablePersistentEmbeddingWorker = useTier2
        let session = ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: sessionOptions)
        let result = try session.indexRoot(url)
        let groups = try indexer.computeDuplicateGroups()
        print("profile=\(profile.rawValue) tier2=\(useTier2) provider=\(indexer.embeddingProvider.providerID)")
        print("index-root=\(result.rootPath) completion=\(result.completion.rawValue) indexed=\(result.processed) scanned=\(result.scanned) missing=\(result.missingMarked) unreadable-directories=\(result.unreadableDirectories) cancelled=\(result.cancelled) paused=\(result.paused) elapsed=\(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        let metrics = indexer.workMetrics
        print("work-metrics visionCalls=\(metrics.visionCalls) ocrCalls=\(metrics.ocrCalls) clipCalls=\(metrics.clipCalls) textEmbedCalls=\(metrics.textEmbedCalls) decodeCalls=\(metrics.decodeCalls)")
        let similarity = indexer.similarityMetrics
        print("similarity-metrics seconds=\(String(format: "%.4f", similarity.seconds)) changedNodes=\(similarity.changedNodes) edges=\(similarity.edges) clusters=\(similarity.clusters)")
        print("duplicate groups: \(groups.count)")
        for g in groups.prefix(20) {
            print("  exact-dupes: \(g.joined(separator: ", "))")
        }
    case "search":
        guard let q = positional(0), let catalogPath = argValue("--catalog") else {
            printUsage(); exit(2)
        }
        let profile = try requestedLocalModelProfile()
        let useTier2 = tier2Enabled(for: profile)
        let catalog = try openCatalog(catalogPath)
        let provider = argValue("--provider").map { EmbeddingProviderFactory.make(kind: $0) }
        let svc = SearchService(catalog: catalog, enableLocalEmbeddings: useTier2,
                                localModelProfile: profile,
                                embeddingProvider: provider)
        for hit in try svc.search(q) {
            print("\(hit.fileID)  rank=\(hit.rank ?? 0)  \((hit.path as NSString).lastPathComponent)")
            if let snip = hit.snippet { print("    \(snip.replacingOccurrences(of: "\n", with: " "))") }
        }
    case "status":
        guard let catalogPath = argValue("--catalog") else { printUsage(); exit(2) }
        let catalog = try openCatalog(catalogPath)
        let counts = try catalog.counts()
        print(counts.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " "))
        print("encrypted-on-disk=\(!Catalog.onDiskHeaderIsPlaintextSQLite(path: catalogPath))")
    case "dupes":
        guard let catalogPath = argValue("--catalog") else { printUsage(); exit(2) }
        let catalog = try openCatalog(catalogPath)
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        let groups = try indexer.computeDuplicateGroups()
        print("duplicate groups: \(groups.count)")
        for g in groups { print("  " + g.joined(separator: ", ")) }
    case "graph-stats":
        guard let catalogPath = argValue("--catalog") else { printUsage(); exit(2) }
        let catalog = try openCatalog(catalogPath)
        let graph = try catalog.organizationGraph()
        print("graph-nodes=\(graph.nodes.count) graph-edges=\(graph.edges.count)")
    case "tree":
        guard let catalogPath = argValue("--catalog") else { printUsage(); exit(2) }
        let catalog = try openCatalog(catalogPath)
        let rows = try catalog.query("""
            SELECT c.name, m.file_id FROM category_membership m
            JOIN virtual_categories c ON c.id = m.category_id
            """) { r in (r.text(0) ?? "", r.text(1) ?? "") }
        var byCat: [String: [String]] = [:]
        for (cat, fid) in rows { byCat[cat, default: []].append(fid) }
        for cat in byCat.keys.sorted() {
            print(cat)
            for fid in byCat[cat]!.sorted() { print("  - \(fid)") }
        }
    case "provider-smoke":
        let samples = max(1, Int(argValue("--samples") ?? "5") ?? 5)
        try runProviderSmoke(samples: samples)
    case "specialist-smoke":
        let profile = try requestedLocalModelProfile()
        let samples = max(1, Int(argValue("--samples") ?? "5") ?? 5)
        try runSpecialistSmoke(profile: profile, samples: samples)
    default:
        printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
