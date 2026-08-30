import Foundation

extension SourceBroker {
    /// Stream a source tree in deterministic lexical order without ever
    /// materializing the complete file list. Only one directory listing per
    /// recursion level plus `batchSize` discovered paths are resident.
    ///
    /// Returning `false` from `body` stops traversal cooperatively. This is the
    /// primitive used by large cancellable indexing sessions.
    @discardableResult
    public static func enumerateBatches(
        root: URL,
        maxDepth: Int = 16,
        excludedPrefixes: [String] = [],
        excludedDirectoryNames: Set<String> = [],
        maxItems: Int? = nil,
        batchSize: Int = 512,
        onUnreadableDirectory: ((String) -> Void)? = nil,
        _ body: ([DiscoveredItem]) throws -> Bool
    ) throws -> Int {
        let broker = SourceBroker()
        let fileManager = FileManager.default
        let limit = maxItems.map { max(0, $0) }
        if limit == 0 { return 0 }

        // `identity(at:)` rejects arbitrary symlink components. The three
        // macOS compatibility aliases are allowed as intermediate components;
        // an explicitly selected arbitrary symlink root remains non-traversable.
        let rootIdentity = try? broker.identity(at: root.path)
        let systemAliasRoot = ["/tmp", "/var", "/etc"].contains(root.path)
        guard systemAliasRoot || (rootIdentity?.isSymlink == false && broker.isDirectory(at: root.path)) else {
            return 0
        }

        var baseDisplay = root.path
        if baseDisplay.hasSuffix("/") && baseDisplay.count > 1 {
            baseDisplay.removeLast()
        }
        let exclusions = excludedPrefixes.map {
            $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0
        }
        if exclusions.contains(where: { SourceBroker.isPath(baseDisplay, under: $0) }) { return 0 }
        if OnboardingExclusions.isExcludedDirectoryName(
            root.lastPathComponent, configured: excludedDirectoryNames) { return 0 }

        var batch: [DiscoveredItem] = []
        batch.reserveCapacity(max(1, batchSize))
        var discovered = 0
        var shouldContinue = true

        func flush() throws -> Bool {
            guard !batch.isEmpty else { return shouldContinue }
            let current = batch
            batch.removeAll(keepingCapacity: true)
            shouldContinue = try body(current)
            return shouldContinue
        }

        func emit(_ item: DiscoveredItem) throws -> Bool {
            guard shouldContinue else { return false }
            if let limit, discovered >= limit { return false }
            batch.append(item)
            discovered += 1
            if batch.count >= max(1, batchSize) {
                return try flush()
            }
            return limit.map { discovered < $0 } ?? true
        }

        func walk(realDirectory: URL, displayDirectory: String, depth: Int) throws -> Bool {
            guard shouldContinue else { return false }
            let contents: [URL]
            do {
                contents = try fileManager.contentsOfDirectory(
                    at: realDirectory,
                    includingPropertiesForKeys: [.isSymbolicLinkKey, .isPackageKey],
                    options: [])
            } catch {
                onUnreadableDirectory?(displayDirectory)
                return true
            }

            for child in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard shouldContinue else { return false }
                if let limit, discovered >= limit { return false }

                let parent = displayDirectory.hasSuffix("/") && displayDirectory.count > 1
                    ? String(displayDirectory.dropLast()) : displayDirectory
                let childDisplay = parent == "/"
                    ? "/" + child.lastPathComponent
                    : parent + "/" + child.lastPathComponent

                if exclusions.contains(where: { SourceBroker.isPath(childDisplay, under: $0) }) { continue }
                if OnboardingExclusions.isExcludedDirectoryName(
                    child.lastPathComponent, configured: excludedDirectoryNames) { continue }
                if OnboardingExclusions.isTransientOrSystemFile(path: childDisplay) { continue }

                // Broker identity is the no-follow authority. A failed identity
                // is not safe to recurse through.
                guard let identity = try? broker.identity(at: childDisplay) else { continue }
                if identity.isSymlink {
                    if try !emit(DiscoveredItem(path: childDisplay, depth: depth)) { return false }
                    continue
                }

                if broker.isDirectory(at: childDisplay) {
                    let package = (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                        || SourceBroker.classify(path: childDisplay) == .package
                        || SourceBroker.classify(path: childDisplay) == .application
                    if package {
                        if try !emit(DiscoveredItem(path: childDisplay, depth: depth)) { return false }
                    } else if depth < maxDepth {
                        // Recurse immediately. Because siblings are sorted this
                        // preserves global lexical path order without a final
                        // all-paths sort.
                        if try !walk(realDirectory: child,
                                     displayDirectory: childDisplay,
                                     depth: depth + 1) { return false }
                    }
                    continue
                }

                if try !emit(DiscoveredItem(path: childDisplay, depth: depth)) { return false }
            }
            return true
        }

        _ = try walk(realDirectory: root, displayDirectory: baseDisplay, depth: 0)
        if shouldContinue { _ = try flush() }
        return discovered
    }
}
