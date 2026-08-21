import Foundation
import LibrarianCore

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
      librarian-cli search <query> --catalog <path>     FTS5 search inside the encrypted catalog
      librarian-cli status  --catalog <path>            Show catalog counts
      librarian-cli dupes   --catalog <path>            Compute exact duplicate groups
      librarian-cli tree    --catalog <path>            Print virtual category tree

    The catalog is SQLCipher-encrypted; its key lives in the macOS Keychain.
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

func positional(_ index: Int) -> String? {
    let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
    return args.count > index ? args[index] : nil
}

func openCatalog(_ catalogPath: String) throws -> Catalog {
    let key = try CatalogKeychain.loadOrCreate()
    return try Catalog(path: catalogPath, key: key)
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
        if url.startAccessingSecurityScopedResource() {
            defer { url.stopAccessingSecurityScopedResource() }
        }
        let catalog = try openCatalog(catalogPath)
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        let t0 = Date()
        let n = try indexer.indexRoot(url)
        let groups = try indexer.computeDuplicateGroups()
        print("indexed \(n) files in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        print("duplicate groups: \(groups.count)")
        for g in groups.prefix(20) {
            print("  exact-dupes: \(g.joined(separator: ", "))")
        }
    case "search":
        guard let q = positional(0), let catalogPath = argValue("--catalog") else {
            printUsage(); exit(2)
        }
        let catalog = try openCatalog(catalogPath)
        let svc = SearchService(catalog: catalog)
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
    default:
        printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
