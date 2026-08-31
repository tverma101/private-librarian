import Foundation
import LibrarianCore
import CoreGraphics
import ImageIO

/// librarian-cli — verification harness for the librarian core.
/// Every subcommand is read-only with respect to source folders.
/// Catalog lives under the caller-specified path (tests use temp dirs).
import Foundation

let io = FileHandle.standardOutput

func printUsage() {
    let text = """
    librarian-cli — Private Local Librarian (read-only verification harness)

    USAGE:
      librarian-cli index <folder> --catalog <path>     Index a folder into an encrypted catalog
      librarian-cli search <query> --catalog <path> [--tier2] [--provider <kind>]
                                                          Search inside the encrypted catalog
      librarian-cli status  --catalog <path>            Show catalog counts
    librarian-cli dupes   --catalog <path>            Compute exact duplicate groups
    librarian-cli graph-stats --catalog <path>         Measure virtual graph query size
    librarian-cli tree    --catalog <path>            Print virtual category tree
    librarian-cli provider-smoke [--samples <n>]      Measure genuine MobileCLIP image/text inference

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
    let args = CommandLine.arguments.dropFirst(2).filter { !$0.hasPrefix("--") }
    return args.count > index ? args[index] : nil
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

func runProviderSmoke(samples: Int) throws {
    let provider = CoreMLMobileCLIPProvider()
    let preflight = provider.preflight
    if !preflight.available {
        print(String(data: try JSONSerialization.data(withJSONObject: [
            "provider": provider.providerID,
            "status": "unavailable",
            "reason": preflight.reason,
            "artifacts": preflight.artifacts,
            "dependencies": preflight.dependencies,
        ], options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
        return
    }
    guard let imageBytes = deterministicPNG() else { throw NSError(domain: "provider-smoke", code: 1) }
    let query = "a red square"
    var imageLatencies: [Double] = []
    var textLatencies: [Double] = []
    var image: EmbeddingVector?
    var text: EmbeddingVector?
    let coldImageStart = Date().timeIntervalSinceReferenceDate
    image = provider.embedImageBytes(imageBytes)
    let coldImageLatency = (Date().timeIntervalSinceReferenceDate - coldImageStart) * 1000
    let coldTextStart = Date().timeIntervalSinceReferenceDate
    text = provider.embedJointText(query)
    let coldTextLatency = (Date().timeIntervalSinceReferenceDate - coldTextStart) * 1000
    for _ in 0..<max(1, samples) {
        let imageStart = Date().timeIntervalSinceReferenceDate
        image = provider.embedImageBytes(imageBytes)
        imageLatencies.append((Date().timeIntervalSinceReferenceDate - imageStart) * 1000)
        let textStart = Date().timeIntervalSinceReferenceDate
        text = provider.embedJointText(query)
        textLatencies.append((Date().timeIntervalSinceReferenceDate - textStart) * 1000)
    }
    guard let image, let text,
          image.dim == CoreMLMobileCLIPProvider.dimension,
          text.dim == CoreMLMobileCLIPProvider.dimension,
          image.spaceID == text.spaceID,
          let cosine = LocalModelBridge.cosineSimilarity(image.data, text.data) else {
        throw NSError(domain: "provider-smoke", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "MobileCLIP did not produce matching 512-D image/text vectors"])
    }
    let result: [String: Any] = [
        "provider": provider.providerID,
        "status": "measured",
        "fixture": "deterministic-red-square-v1",
        "space_id": image.spaceID,
        "dimensions": ["image": image.dim, "text": text.dim],
        "text_to_image_cosine": cosine,
        "cold_image_latency_ms": coldImageLatency,
        "cold_text_latency_ms": coldTextLatency,
        "image_latency_ms": ["p50": percentile(imageLatencies, 0.50), "p95": percentile(imageLatencies, 0.95)],
        "text_latency_ms": ["p50": percentile(textLatencies, 0.50), "p95": percentile(textLatencies, 0.95)],
        "warm_calls": max(1, samples),
    ]
    print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
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
        options.enableLocalEmbeddings = hasFlag("--tier2")
        options.embeddingProviderKind = argValue("--provider")
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler(), options: options)
        let t0 = Date()
        var sessionOptions = ScalableIndexSession.Options()
        sessionOptions.enablePersistentEmbeddingWorker = hasFlag("--tier2")
        let session = ScalableIndexSession(
            broker: broker, catalog: catalog, indexer: indexer, options: sessionOptions)
        let result = try session.indexRoot(url)
        let groups = try indexer.computeDuplicateGroups()
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
        let catalog = try openCatalog(catalogPath)
        let provider = argValue("--provider").map { EmbeddingProviderFactory.make(kind: $0) }
        let svc = SearchService(catalog: catalog, enableLocalEmbeddings: hasFlag("--tier2"),
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
    default:
        printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
