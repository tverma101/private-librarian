import Foundation
#if canImport(Darwin)
import Darwin
#endif

private enum EnumerationControlError: Error {
    case cancelled
}

/// Lexical direct-child cursor with a bounded-memory fast path and a
/// disk-backed external-sort path for very large directories. Directory
/// entries are never accumulated in the process heap in proportion to the
/// directory size, while callers still receive the historical deterministic
/// traversal order.
private final class SortedDirectoryCursor {
    private static let inMemoryEntryLimit = 4_096

    private var inMemoryNames: [String]
    private var inMemoryIndex = 0
    private var diskReader: HexLineReader?
    private var temporaryDirectory: URL?

    init(directory: URL, shouldContinue: @escaping () -> Bool = { true }) throws {
        self.inMemoryNames = []
        self.diskReader = nil
        self.temporaryDirectory = nil

        let fileManager = FileManager.default
        let directoryPath = directory.path.hasSuffix("/") && directory.path.count > 1
            ? String(directory.path.dropLast()) : directory.path
        let prefix = directoryPath == "/" ? "/" : directoryPath + "/"
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []) else {
            throw BrokerError.statFailed(EACCES)
        }

        var buffered: [String] = []
        buffered.reserveCapacity(Self.inMemoryEntryLimit)
        var writer: FileHandle?
        var inputURL: URL?
        var cleanupOnFailure = true
        defer {
            try? writer?.close()
            if cleanupOnFailure, let temporaryDirectory {
                try? fileManager.removeItem(at: temporaryDirectory)
            }
        }

        while let candidate = enumerator.nextObject() as? URL {
            guard shouldContinue() else { throw EnumerationControlError.cancelled }
            let candidatePath = candidate.path
            guard candidatePath.hasPrefix(prefix) else { continue }
            let relative = String(candidatePath.dropFirst(prefix.count))
            // Direct children are the only entries this cursor owns. A
            // directory's descendants are skipped as soon as that directory
            // is encountered so the next call remains a direct-child read.
            guard !relative.isEmpty, !relative.contains("/") else { continue }
            let name = candidate.lastPathComponent

            if writer == nil && buffered.count < Self.inMemoryEntryLimit {
                buffered.append(name)
            } else {
                if writer == nil {
                    let temp = fileManager.temporaryDirectory
                        .appendingPathComponent("private-librarian-enum-\(UUID().uuidString)", isDirectory: true)
                    try fileManager.createDirectory(at: temp, withIntermediateDirectories: true)
                    let input = temp.appendingPathComponent("entries.hex")
                    guard fileManager.createFile(atPath: input.path, contents: nil) else {
                        throw BrokerError.statFailed(EIO)
                    }
                    let handle = try FileHandle(forWritingTo: input)
                    for existing in buffered {
                        try handle.write(contentsOf: Self.encode(existing))
                    }
                    buffered.removeAll(keepingCapacity: false)
                    temporaryDirectory = temp
                    inputURL = input
                    writer = handle
                }
                try writer?.write(contentsOf: Self.encode(name))
            }

            var status = stat()
            if lstat(candidatePath, &status) == 0 {
                let mode = status.st_mode & S_IFMT
                if mode == S_IFDIR || mode == S_IFLNK {
                    enumerator.skipDescendants()
                }
            }
        }

        if let writer, let inputURL, let temporaryDirectory {
            try writer.close()
            let outputURL = temporaryDirectory.appendingPathComponent("sorted.hex")
            guard fileManager.createFile(atPath: outputURL.path, contents: nil) else {
                throw BrokerError.statFailed(EIO)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sort")
            process.arguments = ["-u", inputURL.path, "-o", outputURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment["LC_ALL"] = "C"
            process.environment = environment
            try process.run()
            while process.isRunning {
                guard shouldContinue() else {
                    process.terminate()
                    process.waitUntilExit()
                    throw EnumerationControlError.cancelled
                }
#if canImport(Darwin)
                usleep(10_000)
#endif
            }
            guard process.terminationStatus == 0 else {
                throw BrokerError.statFailed(EIO)
            }
            diskReader = try HexLineReader(file: outputURL)
        } else {
            inMemoryNames = buffered.sorted { $0 < $1 }
        }
        cleanupOnFailure = false
    }

    deinit {
        try? diskReader?.close()
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func next() -> String? {
        if let diskReader { return diskReader.next() }
        guard inMemoryIndex < inMemoryNames.count else { return nil }
        defer { inMemoryIndex += 1 }
        return inMemoryNames[inMemoryIndex]
    }

    private static func encode(_ value: String) -> Data {
        let hex = value.utf8.map { String(format: "%02x", $0) }.joined()
        return Data((hex + "\n").utf8)
    }
}

private final class HexLineReader {
    private let handle: FileHandle
    private var buffer = Data()
    private var reachedEOF = false

    init(file: URL) throws {
        handle = try FileHandle(forReadingFrom: file)
    }

    deinit { try? handle.close() }

    func close() throws { try handle.close() }

    func next() -> String? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                return Self.decode(line)
            }
            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                let line = buffer
                buffer.removeAll(keepingCapacity: false)
                return Self.decode(line)
            }
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  !chunk.isEmpty else {
                reachedEOF = true
                continue
            }
            buffer.append(chunk)
        }
    }

    private static func decode(_ line: Data) -> String? {
        guard line.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(line.count / 2)
        let digits = Array(line)
        var index = 0
        while index < digits.count {
            guard let high = hexValue(digits[index]), let low = hexValue(digits[index + 1]) else {
                return nil
            }
            bytes.append((high << 4) | low)
            index += 2
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 97...102: return byte - 87
        case 65...70: return byte - 55
        default: return nil
        }
    }
}

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
        continuePredicate: (() -> Bool)? = nil,
        onUnreadableDirectory: ((String, String) -> Void)? = nil,
        onRootUnavailable: ((String, String) -> Void)? = nil,
        _ body: ([DiscoveredItem]) throws -> Bool
    ) throws -> Int {
        let broker = SourceBroker()
        let limit = maxItems.map { max(0, $0) }
        if limit == 0 { return 0 }

        // `identity(at:)` rejects arbitrary symlink components. The three
        // macOS compatibility aliases are allowed as intermediate components;
        // an explicitly selected arbitrary symlink root remains non-traversable.
        func unreadableReason(_ error: Error) -> String {
            if case BrokerError.statFailed(let code) = error {
                if code == EACCES || code == EPERM { return "permission-denied" }
                return "unreadable:\(code)"
            }
            let ns = error as NSError
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            let code = underlying?.code ?? ns.code
            if code == Int(EACCES) || code == Int(EPERM) { return "permission-denied" }
            return "unreadable:\(code)"
        }

        let rootIdentity: FileIdentity?
        do {
            rootIdentity = try broker.identity(at: root.path)
        } catch {
            onRootUnavailable?(root.path, unreadableReason(error))
            return 0
        }
        let systemAliasRoot = ["/tmp", "/var", "/etc"].contains(root.path)
        guard systemAliasRoot || (rootIdentity?.isSymlink == false && broker.isDirectory(at: root.path)) else {
            onRootUnavailable?(root.path, "not-directory")
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

        // Foundation's DirectoryEnumerator is used by the direct-child cursor
        // below. Unlike contentsOfDirectory, it does not allocate an array
        // proportional to a huge directory; the cursor external-sorts large
        // sibling sets through a bounded temporary file.
        let rootPath = root.path.hasSuffix("/") && root.path.count > 1
            ? String(root.path.dropLast()) : root.path
        // Foundation's URL resolver does not consistently rewrite the macOS
        // compatibility aliases when DirectoryEnumerator returns canonical
        // child URLs. Mirror the broker's small explicit alias policy so the
        // emitted path spelling and the enumerator's real path stay aligned.
        let realRootPath: String
        if rootPath == "/var" || rootPath.hasPrefix("/var/") {
            realRootPath = "/private" + rootPath
        } else if rootPath == "/tmp" || rootPath.hasPrefix("/tmp/") {
            realRootPath = "/private" + rootPath
        } else if rootPath == "/etc" || rootPath.hasPrefix("/etc/") {
            realRootPath = "/private" + rootPath
        } else {
            // The root has already passed the broker's no-follow validation.
            // Keep its caller spelling: Foundation can rewrite `/private/tmp`
            // to `/tmp` even when the enumerator returns `/private/tmp/...`.
            realRootPath = rootPath
        }
        let realRoot = URL(fileURLWithPath: realRootPath)
        let continueCheck: () -> Bool = continuePredicate ?? { true }

        func canOpenDirectory(_ path: String) -> (Bool, String) {
#if canImport(Darwin)
            errno = 0
            guard let handle = opendir(path) else {
                let code = errno
                if code == EACCES || code == EPERM { return (false, "permission-denied") }
                return (false, "unreadable:\(code)")
            }
            closedir(handle)
#endif
            return (true, "")
        }

        func walk(realDirectory: URL, displayDirectory: String, depth: Int) throws -> Bool {
            guard shouldContinue, continueCheck() else { return false }
            let cursor: SortedDirectoryCursor
            do {
                cursor = try SortedDirectoryCursor(
                    directory: realDirectory, shouldContinue: continueCheck)
            } catch EnumerationControlError.cancelled {
                shouldContinue = false
                return false
            } catch {
                if realDirectory.path == realRootPath {
                    onRootUnavailable?(baseDisplay, unreadableReason(error))
                } else {
                    onUnreadableDirectory?(displayDirectory, unreadableReason(error))
                }
                return true
            }

            while shouldContinue, continueCheck(), let name = cursor.next() {
                if let limit, discovered >= limit { return false }
                let child = realDirectory.appendingPathComponent(name)
                let parent = displayDirectory.hasSuffix("/") && displayDirectory.count > 1
                    ? String(displayDirectory.dropLast()) : displayDirectory
                let childDisplay = parent == "/" ? "/" + name : parent + "/" + name

                if exclusions.contains(where: { SourceBroker.isPath(childDisplay, under: $0) }) {
                    continue
                }
                if OnboardingExclusions.isExcludedDirectoryName(
                    name, configured: excludedDirectoryNames) {
                    continue
                }
                if OnboardingExclusions.isTransientOrSystemFile(path: childDisplay) {
                    continue
                }

                // Broker identity is the no-follow authority. Permission
                // failures are recorded at the prefix, not once per child.
                let identity: FileIdentity
                do {
                    identity = try broker.identity(at: childDisplay)
                } catch BrokerError.statFailed(let error)
                    where error == EACCES || error == EPERM {
                    onUnreadableDirectory?(childDisplay, "permission-denied")
                    continue
                } catch {
                    continue
                }

                if identity.isSymlink {
                    if try !emit(DiscoveredItem(path: childDisplay, depth: depth)) { return false }
                    continue
                }

                if broker.isDirectory(at: childDisplay) {
                    let (readable, reason) = canOpenDirectory(child.path)
                    guard readable else {
                        onUnreadableDirectory?(childDisplay, reason)
                        continue
                    }
                    let package = (try? child.resourceValues(forKeys: [.isPackageKey]).isPackage) == true
                        || SourceBroker.classify(path: childDisplay) == .package
                        || SourceBroker.classify(path: childDisplay) == .application
                    if package {
                        if try !emit(DiscoveredItem(path: childDisplay, depth: depth)) { return false }
                    } else if depth < maxDepth {
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

        _ = try walk(realDirectory: realRoot, displayDirectory: baseDisplay, depth: 0)
        if shouldContinue { _ = try flush() }
        return discovered
    }
}
