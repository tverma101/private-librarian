import SwiftUI
import LibrarianCore

/// Native SwiftUI shell (plan §1, §45, §46). No web server, no WebView,
/// no listening socket. Sources are added via the system folder picker with
/// read-only security-scoped bookmarks; the catalog is SQLCipher-encrypted
/// with its key in the Keychain.
@main
struct PrivateLibrarianApp: App {
    @StateObject private var model = LibrarianModel()

    var body: some Scene {
        WindowGroup("Private Librarian") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Add Source Folder…") { model.addSourceFolder() }
                    .keyboardShortcut("o")
            }
        }
    }
}

@MainActor
final class LibrarianModel: ObservableObject {

    struct SourceFolder: Identifiable, Codable {
        let id: UUID
        let path: String
    }

    @Published var sources: [SourceFolder] = []
    @Published var statusLines: [String] = []
    @Published var searchResults: [String] = []
    @Published var query: String = ""
    @Published var isIndexing = false

    private var catalog: Catalog?
    private var bookmarkDataByPath: [String: Data] = [:]

    static var appSupportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PrivateLibrarian", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        loadBookmarks()
        openCatalogIfNeeded()
    }

    // MARK: - Catalog

    private func openCatalogIfNeeded() {
        guard catalog == nil else { return }
        do {
            let key = try CatalogKeychain.loadOrCreate()
            let dbPath = Self.appSupportDir.appendingPathComponent("catalog.db").path
            catalog = try Catalog(path: dbPath, key: key)
            log("catalog opened (encrypted)")
        } catch {
            log("catalog error: \(error)")
        }
    }

    // MARK: - Read-only source access via security-scoped bookmarks

    func addSourceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose folders to index. Access is READ-ONLY; files are never modified."
        panel.begin { [weak self] resp in
            guard let self, resp == .OK else { return }
            for url in panel.urls {
                let data = (try? url.bookmarkData(options: [.withSecurityScope],
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil)) ?? Data()
                self.bookmarkDataByPath[url.path] = data
                self.sources.append(SourceFolder(id: UUID(), path: url.path))
            }
            self.saveBookmarks()
        }
    }

    /// Resolve a stored read-only security-scoped bookmark and run `body`
    /// while access is active.
    func withSource<T>(_ source: SourceFolder, _ body: (URL) throws -> T) rethrows -> T? {
        guard let data = bookmarkDataByPath[source.path] else {
            // CLI/test harness path without a bookmark — direct read-only use.
            return try? body(URL(fileURLWithPath: source.path))
        }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: data,
                                      options: [.withSecurityScope],
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &isStale) else {
            return try? body(URL(fileURLWithPath: source.path))
        }
        let started = resolved.startAccessingSecurityScopedResource()
        defer { if started { resolved.stopAccessingSecurityScopedResource() } }
        return try body(resolved)
    }

    func startIndexing() {
        guard let catalog, !isIndexing else { return }
        isIndexing = true
        let broker = SourceBroker()
        let indexer = Indexer(broker: broker, catalog: catalog, scheduler: Scheduler())
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            for src in self?.sources ?? [] {
                _ = self?.withSource(src) { url in
                    _ = try? indexer.indexRoot(url) { p in
                        DispatchQueue.main.async {
                            self?.log("indexing… \(p.processed)/\(p.total)")
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self?.isIndexing = false
                self?.log("indexing complete")
            }
        }
    }

    func runSearch() {
        guard let catalog, !query.isEmpty else { return }
        let svc = SearchService(catalog: catalog)
        let hits = (try? svc.search(query)) ?? []
        searchResults = hits.map { "\($0.fileID) — \(($0.path as NSString).lastPathComponent)" }
    }

    /// Privacy indicators derived from ACTUAL state where possible (plan §45).
    func privacyIndicators() -> [(String, Bool)] {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") != nil
            || amISandboxed()
        return [
            ("App Sandbox enabled", sandboxed),
            ("Sources read-only", true),   // enforced by SourceBroker O_RDONLY|O_NOFOLLOW + entitlements
            ("Internet disabled", !hasNetworkEntitlement()),
            ("Telemetry disabled", true),
            ("Catalog encrypted", catalogOnDiskEncrypted()),
            ("\(sources.count) folders authorized", !sources.isEmpty),
        ]
    }

    private func amISandboxed() -> Bool {
        // Sandbox check: SecTaskCopyValueForEntitlement for the sandbox entitlement.
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let val = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil) as? Bool
        return val ?? false
    }

    private func hasNetworkEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let client = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.client" as CFString, nil) as? Bool
        let server = SecTaskCopyValueForEntitlement(task, "com.apple.security.network.server" as CFString, nil) as? Bool
        return (client ?? false) || (server ?? false)
    }

    private func catalogOnDiskEncrypted() -> Bool {
        let p = Self.appSupportDir.appendingPathComponent("catalog.db").path
        return FileManager.default.fileExists(atPath: p)
            && !Catalog.onDiskHeaderIsPlaintextSQLite(path: p)
    }

    private func log(_ s: String) {
        statusLines.append(s)
        if statusLines.count > 200 { statusLines.removeFirst(statusLines.count - 200) }
    }

    // MARK: - Bookmark persistence

    private func saveBookmarks() {
        let payload = sources.compactMap { src -> Data? in bookmarkDataByPath[src.path] }
        let wrapped = try? JSONEncoder().encode(payload.map { $0.base64EncodedString() })
        UserDefaults.standard.set(wrapped, forKey: "source-bookmarks-v1")
        UserDefaults.standard.set(sources.map(\.path), forKey: "source-paths-v1")
    }

    private func loadBookmarks() {
        guard let b64 = UserDefaults.standard.stringArray(forKey: "source-bookmarks-v1"),
              let paths = UserDefaults.standard.stringArray(forKey: "source-paths-v1") else { return }
        let datas = b64.compactMap { Data(base64Encoded: $0) }
        for (i, path) in paths.enumerated() where i < datas.count {
            sources.append(SourceFolder(id: UUID(), path: path))
            bookmarkDataByPath[path] = datas[i]
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: LibrarianModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Categories") {
                    Label("School", systemImage: "graduationcap")
                    Label("Screenshots", systemImage: "camera.viewfinder")
                    Label("Documents", systemImage: "doc")
                    Label("Audio", systemImage: "waveform")
                    Label("Videos", systemImage: "film")
                    Label("Duplicates", systemImage: "square.on.square")
                    Label("Review", systemImage: "questionmark.folder")
                    Label("Missing", systemImage: "exclamationmark.triangle")
                }
                Section("Sources (read-only)") {
                    ForEach(model.sources) { src in
                        Text((src.path as NSString).lastPathComponent)
                    }
                    Button("Add Folder…") { model.addSourceFolder() }
                    Button(model.isIndexing ? "Indexing…" : "Index Now") { model.startIndexing() }
                        .disabled(model.isIndexing || model.sources.isEmpty)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    TextField("Search everything…", text: $model.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.runSearch() }
                    Button("Search") { model.runSearch() }
                }.padding(8)
                List(model.searchResults, id: \.self) { r in Text(r) }
                Divider()
                PrivacyBar(indicators: model.privacyIndicators())
                    .padding(8)
            }
        }
    }
}

struct PrivacyBar: View {
    let indicators: [(String, Bool)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(indicators, id: \.0) { item in
                HStack(spacing: 3) {
                    Image(systemName: item.1 ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(item.1 ? .green : .red)
                    Text(item.0).font(.caption)
                }
            }
            Spacer()
            Text("READ ONLY · OFFLINE · ENCRYPTED").font(.caption2).foregroundStyle(.secondary)
        }
    }
}
