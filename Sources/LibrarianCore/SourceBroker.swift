import Foundation
import UniformTypeIdentifiers

/// Deterministic, ML-free owner of all source-folder access.
///
/// Security contract:
/// - Opens source files O_RDONLY only (C `open`, never FileHandle write APIs).
/// - Never follows symlinks: a symlink is indexed as metadata (`kind == .symlink`)
///   and its target is never opened or traversed. This is enforced with
///   `O_NOFOLLOW` + `O_EVTONLY`-style flags at the syscall layer, independent
///   of any sandbox.
/// - Never mutates: no rename/unlink/chmod/setxattr/truncate/write paths exist
///   in this file. The only syscalls used are open(O_RDONLY|O_NOFOLLOW|O_CLOEXEC),
///   fstat, read, close.
/// - Emits bounded data to workers; workers never see folder authority.
public struct SourceBroker: Sendable {

    /// Hard cap on bytes read from any single file per analysis pass.
    public let maxReadBytes: Int64
    /// Files larger than this are treated as huge: metadata-only unless a
    /// worker explicitly streams within the cap.
    public let hugeFileThreshold: Int64
    /// Maximum complete source snapshot permitted for container metadata/frame work.
    /// Oversize media is fail-closed rather than analyzed from a truncated prefix.
    public let maxSnapshotBytes: Int64

    public init(maxReadBytes: Int64 = 8 * 1024 * 1024,
                hugeFileThreshold: Int64 = 2 * 1024 * 1024 * 1024,
                maxSnapshotBytes: Int64 = 256 * 1024 * 1024) {
        self.maxReadBytes = maxReadBytes
        self.hugeFileThreshold = hugeFileThreshold
        self.maxSnapshotBytes = maxSnapshotBytes
    }

    // MARK: - Identity

    /// Stat a path WITHOUT following symlinks (lstat semantics).
    /// NOTE: deliberately NO extra canonicalization here — the enumerator is
    /// the single source of path spelling (mixing standardized and raw forms
    /// made the missing-file sweep see phantom deletions).
    public func identity(at path: String) throws -> FileIdentity {
        return try Self.identityNoFollow(path: path)
    }

    static func identityNoFollow(path: String) throws -> FileIdentity {
        _ = try noFollowPath(path, allowFinalSymlink: true, lstatErrorsAsStatFailures: true)
        var st = stat()
        let rc = lstat(path, &st)
        guard rc == 0 else { throw BrokerError.statFailed(errno) }

        let isLink = (st.st_mode & S_IFMT) == S_IFLNK
        let kind: FileKind
        if isLink {
            kind = .symlink
        } else if (st.st_mode & S_IFMT) != S_IFREG {
            kind = .other
        } else {
            kind = Self.classify(path: path)
        }
        return FileIdentity(
            path: path,
            volumeUUID: Self.volumeUUID(forPath: path),
            fileID: UInt64(st.st_ino),
            size: Int64(st.st_size),
            mtime: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)),
            ctime: Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec)),
            kind: kind,
            isSymlink: isLink
        )
    }

    static func volumeUUID(forPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]) else { return nil }
        return values.volumeUUIDString
    }

    /// Check directory-ness without following the final path component.
    /// Callers that need to recurse should use this after identity validation.
    public func isDirectory(at path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: - Kind classification

    public static func classify(path: String) -> FileKind {
        let lastComponent = (path as NSString).lastPathComponent
        // Package/bundle detection by extension — do not descend in v1.
        for pkgExt in ["app", "photoslibrary", "bundle", "framework", "xcodeproj",
                       "docset", "playground", "rtfd", "draftsBundle", "moverbundle"] where lastComponent.hasSuffix("." + pkgExt) {
            return pkgExt == "app" ? .application : .package
        }
        guard let ut = UTType(filenameExtension: (lastComponent as NSString).pathExtension) else {
            return .other
        }
        if ut.conforms(to: .archive) { return .archive }
        if ut.conforms(to: .diskImage) || lastComponent.hasSuffix(".iso") { return .diskImage }
        if ut.conforms(to: .pdf) { return .pdf }
        if ut.conforms(to: .image) { return .image }
        if ut.conforms(to: .audiovisualContent) {
            if ut.conforms(to: .movie) || ut.conforms(to: .video) { return .video }
            if ut.conforms(to: .audio) { return .audio }
        }
        if ut.conforms(to: .audio) { return .audio }
        if ut.conforms(to: .spreadsheet) || ut.conforms(to: .presentation)
            || lastComponent.lowercased().hasSuffix(".docx")
            || lastComponent.lowercased().hasSuffix(".xlsx")
            || lastComponent.lowercased().hasSuffix(".pptx") {
            return .office
        }
        if ut.conforms(to: .text) || ut.conforms(to: .sourceCode) || ut.conforms(to: .json)
            || ut.conforms(to: .xml) || ut.conforms(to: .yaml) {
            return .text
        }
        return .other
    }

    // MARK: - Read-only access

    /// Open the file strictly read-only and strictly no-follow.
    /// Returns a POSIX fd the caller MUST close (or use `withReadOnlyHandle`).
    /// Throws `BrokerError.isSymlink` for symlinks — they are never opened.
    public func openReadOnly(_ path: String) throws -> Int32 {
        // O_NOFOLLOW protects only the final component. Resolve the caller's
        // spelling through the small set of macOS system aliases, reject every
        // other symlink component, then walk the resolved path with openat +
        // O_NOFOLLOW so a directory cannot be swapped for a symlink mid-walk.
        let resolvedPath = try Self.noFollowPath(path)
        let fd = try Self.openResolvedReadOnly(resolvedPath)
        // Confirm what we opened is a regular file (defends against FIFOs,
        // devices, and TOCTOU swaps between lstat and open).
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw BrokerError.notRegularFile
        }
        return fd
    }

    private static func noFollowPath(_ path: String, allowFinalSymlink: Bool = false,
                                     lstatErrorsAsStatFailures: Bool = false) throws -> String {
        let rawAbsolute = path.hasPrefix("/")
            ? path
            : FileManager.default.currentDirectoryPath + "/" + path
        let normalized = Self.lexicallyStandardizedPath(rawAbsolute)
        let components = normalized.split(separator: "/", omittingEmptySubsequences: true)
        if components.isEmpty { return "/" }

        var spelling = "/"
        var resolved = "/"
        for (index, component) in components.enumerated() {
            let name = String(component)
            spelling = spelling == "/" ? "/" + name : spelling + "/" + name
            var st = stat()
            guard lstat(spelling, &st) == 0 else {
                if lstatErrorsAsStatFailures {
                    throw BrokerError.statFailed(errno)
                }
                throw BrokerError.openFailed(errno)
            }
            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK {
                if allowFinalSymlink && index == components.count - 1 {
                    return resolved == "/" ? "/" + name : resolved + "/" + name
                }
                guard let target = Self.symlinkTarget(at: spelling),
                      Self.isAllowedSystemAlias(spelling, target) else {
                    throw BrokerError.isSymlink
                }
                resolved = target
            } else {
                resolved = resolved == "/" ? "/" + name : resolved + "/" + name
            }
        }
        return resolved
    }

    private static func symlinkTarget(at path: String) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return nil
        }
        let parent = (path as NSString).deletingLastPathComponent
        let rawTarget = destination.hasPrefix("/")
            ? destination
            : (parent == "/" ? "/" + destination : parent + "/" + destination)
        return lexicallyStandardizedPath(rawTarget)
    }

    private static func lexicallyStandardizedPath(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                if !components.isEmpty { components.removeLast() }
            default:
                components.append(component)
            }
        }
        return "/" + components.map(String.init).joined(separator: "/")
    }

    private static func isAllowedSystemAlias(_ spelling: String, _ target: String) -> Bool {
        switch (spelling, target) {
        case ("/var", "/private/var"),
             ("/tmp", "/private/tmp"),
             ("/etc", "/private/etc"):
            return true
        default:
            return false
        }
    }

    private static func openResolvedReadOnly(_ path: String) throws -> Int32 {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = components.last else { throw BrokerError.openFailed(EINVAL) }
        var directoryFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw BrokerError.openFailed(errno) }
        for component in components.dropLast() {
            let next = String(component).withCString {
                openat(directoryFD, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            }
            guard next >= 0 else {
                let error = errno
                close(directoryFD)
                if error == ELOOP {
                    throw BrokerError.isSymlink
                }
                throw BrokerError.openFailed(error)
            }
            close(directoryFD)
            directoryFD = next
        }
        let fd = String(last).withCString {
            openat(directoryFD, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let error = errno
        close(directoryFD)
        guard fd >= 0 else {
            if error == ELOOP {
                throw BrokerError.isSymlink
            }
            throw BrokerError.openFailed(error)
        }
        return fd
    }

    /// Scoped read-only handle; fd is always closed on scope exit.
    public func withReadOnlyHandle<T>(_ path: String, _ body: (Int32) throws -> T) throws -> T {
        let fd = try openReadOnly(path)
        defer { close(fd) }
        return try body(fd)
    }

    /// Bounded read of up to `maxReadBytes` from the head of the file.
    /// Reads via the read-only fd only. Never materializes more than the cap.
    public func boundedRead(_ path: String, limit: Int64? = nil) throws -> Data {
        let cap = min(limit ?? maxReadBytes, maxReadBytes)
        guard cap > 0 else { return Data() }
        return try withReadOnlyHandle(path) { fd in
            var data = Data()
            data.reserveCapacity(Int(min(cap, 1 << 20)))
            var remaining = cap
            let chunkSize = 262_144
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while remaining > 0 {
                let want = Int(min(Int64(chunkSize), remaining))
                let got = read(fd, chunk, want)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw BrokerError.openFailed(errno)
                }
                if got == 0 { break }
                data.append(contentsOf: UnsafeBufferPointer(start: chunk, count: got))
                remaining -= Int64(got)
            }
            return data
        }
    }

    /// Stream a complete source snapshot through the broker without exposing
    /// the source path to a decoder/model. The file is checked before opening
    /// and while streaming; a file over the explicit policy is rejected rather
    /// than copied partially (partial containers are unsafe to decode).
    public func streamCompleteSnapshot(_ path: String, maxBytes: Int64? = nil,
                                       _ body: (Data, Bool) throws -> Void) throws {
        let cap = min(maxBytes ?? maxSnapshotBytes, maxSnapshotBytes)
        guard cap > 0 else { throw BrokerError.snapshotTooLarge(size: 0, limit: cap) }
        try withReadOnlyHandle(path) { fd in
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw BrokerError.openFailed(errno) }
            let declaredSize = Int64(st.st_size)
            guard declaredSize >= 0, declaredSize <= cap else {
                throw BrokerError.snapshotTooLarge(size: declaredSize, limit: cap)
            }

            var total: Int64 = 0
            let chunkSize = 262_144
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while true {
                let got = read(fd, chunk, chunkSize)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw BrokerError.openFailed(errno)
                }
                if got == 0 { break }
                total += Int64(got)
                guard total <= cap else {
                    throw BrokerError.snapshotTooLarge(size: total, limit: cap)
                }
                try body(Data(bytes: chunk, count: got), false)
            }
            var final = stat()
            guard fstat(fd, &final) == 0 else { throw BrokerError.openFailed(errno) }
            var finalPath = stat()
            guard lstat(path, &finalPath) == 0,
                  Self.sameGeneration(initial: st, final: final),
                  Self.sameGeneration(initial: st, final: finalPath) else {
                throw BrokerError.changedDuringRead
            }
            try body(Data(), true)
        }
    }

    /// Complete snapshot convenience for APIs (such as AVFoundation image
    /// generation) that require random access to the broker-owned bytes.
    public func completeSnapshot(_ path: String, maxBytes: Int64? = nil) throws -> Data {
        var out = Data()
        try streamCompleteSnapshot(path, maxBytes: maxBytes) { data, isLast in
            if !isLast { out.append(data) }
        }
        return out
    }

    /// Read exactly `length` bytes starting at `offset` without moving a shared
    /// cursor (pread). Bounded by maxReadBytes. Strictly read-only.
    public func readSlice(path: String, offset: Int64, length: Int64) throws -> Data {
        guard offset >= 0 else { throw BrokerError.openFailed(EINVAL) }
        let cap = min(length, maxReadBytes)
        guard cap > 0 else { return Data() }
        return try withReadOnlyHandle(path) { fd in
            var data = Data()
            data.reserveCapacity(Int(cap))
            var remaining = cap
            var off = offset
            let chunkSize = 262_144
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while remaining > 0 {
                let want = Int(min(Int64(chunkSize), remaining))
                let got = pread(fd, chunk, want, off)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw BrokerError.openFailed(errno)
                }
                if got == 0 { break }
                data.append(contentsOf: UnsafeBufferPointer(start: chunk, count: got))
                off += Int64(got)
                remaining -= Int64(got)
            }
            return data
        }
    }

    /// Stream the ENTIRE file in fixed-size chunks without holding it in
    /// memory. Unlike the analysis reads above there is NO byte cap by
    /// default: a SHA-256 must read every byte. Bounding MEMORY and bounding
    /// TOTAL BYTES are different guarantees — extraction needs the latter,
    /// hashing must not have it. Callers that need a time/IO bound should use
    /// streamHash(cappedAt:) or run the hash on the background Scheduler slot.
    /// Still strictly read-only through the no-follow fd.
    public func streamHash(_ path: String,
                           _ body: (Data, Bool) throws -> Void) throws {
        try withReadOnlyHandle(path) { fd in
            var initial = stat()
            guard fstat(fd, &initial) == 0 else { throw BrokerError.openFailed(errno) }
            let chunkSize = 262_144
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while true {
                let got = read(fd, chunk, chunkSize)
                if got < 0 {
                    if errno == EINTR { continue }
                    throw BrokerError.openFailed(errno)
                }
                if got == 0 { break }
                try body(Data(bytes: chunk, count: got), false)
            }
            var final = stat()
            guard fstat(fd, &final) == 0 else { throw BrokerError.openFailed(errno) }
            var finalPath = stat()
            guard lstat(path, &finalPath) == 0,
                  Self.sameGeneration(initial: initial, final: final),
                  Self.sameGeneration(initial: initial, final: finalPath) else {
                throw BrokerError.changedDuringRead
            }
            try body(Data(), true)
        }
    }

    private static func sameGeneration(initial: stat, final: stat) -> Bool {
        initial.st_dev == final.st_dev
            && initial.st_ino == final.st_ino
            && initial.st_size == final.st_size
            && initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec
            && initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec
            && initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec
            && initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec
    }

    /// Capped streaming variant — shims time/IO bounded callers.
    public func streamHash(cappedAt cap: Int64, path: String,
                           _ body: (Data, Bool) throws -> Void) throws {
        try streamBounded(path, limit: cap, body)
    }

    /// Stream the whole file in chunks without holding it in memory.
    /// Total bytes read are still capped at `maxReadBytes` to bound work.
    public func streamBounded(_ path: String, limit: Int64? = nil,
                              _ body: (Data, Bool) throws -> Void) throws {
        let cap = min(limit ?? maxReadBytes, maxReadBytes)
        try withReadOnlyHandle(path) { fd in
            var remaining = cap
            let chunkSize = 262_144
            let chunk = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { chunk.deallocate() }
            while remaining > 0 {
                let want = Int(min(Int64(chunkSize), remaining))
                let got = read(fd, chunk, want)
                if got <= 0 { break }
                let isLast = got < want || (remaining - Int64(got)) <= 0
                try body(Data(bytes: chunk, count: got), isLast)
                remaining -= Int64(got)
            }
        }
    }

    /// Safe metadata that never requires opening content:
    /// size, dates, kind, plus UTType description string.
    public func safeMetadata(for ident: FileIdentity) -> [String: String] {
        var meta: [String: String] = [
            "size": String(ident.size),
            "mtime": ISO8601DateFormatter.string(from: ident.mtime, timeZone: .current, formatOptions: [.withInternetDateTime]),
            "ctime": ISO8601DateFormatter.string(from: ident.ctime, timeZone: .current, formatOptions: [.withInternetDateTime]),
            "kind": ident.kind.rawValue,
        ]
        let ext = ((ident.path as NSString).lastPathComponent as NSString).pathExtension
        if !ext.isEmpty { meta["extension"] = ext.lowercased() }
        if let ut = UTType(filenameExtension: ext), let desc = ut.localizedDescription {
            meta["ut_description"] = desc
        }
        return meta
    }

    // MARK: - Enumeration

    public struct DiscoveredItem: Sendable {
        public let path: String
        public let depth: Int
    }

    /// Enumerate a security-scoped root WITHOUT following symlinks and WITHOUT
    /// descending into packages/bundles. Returns paths of regular files plus
    /// link records, each built by joining component names onto the CALLER's
    /// root spelling (`root.path`) — FileManager canonicalizes `/var` →
    /// `/private/var` in the child URLs it hands back, and emitting those raw
    /// would put two spellings of the same tree into one index run.
    /// Deterministic order (sorted per directory).
    public static func enumerate(root: URL, maxDepth: Int = 16,
                                 excludedPrefixes: [String] = [],
                                 excludedDirectoryNames: Set<String> = []) throws -> [DiscoveredItem] {
        var out: [DiscoveredItem] = []
        let fm = FileManager.default
        let resolvedRoot: String
        do {
            resolvedRoot = try Self.noFollowPath(root.path)
        } catch {
            // A selected root with a non-system symlink in any component is
            // not a traversal capability. The caller can re-authorize the
            // canonical directory instead.
            return []
        }
        var rootStat = stat()
        guard lstat(resolvedRoot, &rootStat) == 0,
              (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            // An explicitly selected symlink root must never become a
            // traversal capability for its target.
            return []
        }
        var baseDisplay = root.path
        if baseDisplay.hasSuffix("/") && baseDisplay.count > 1 { baseDisplay = String(baseDisplay.dropLast()) }
        let exclusions = excludedPrefixes.map { path in
            path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        if exclusions.contains(where: { Self.isPath(baseDisplay, under: $0) }) { return [] }
        if OnboardingExclusions.isExcludedDirectoryName(root.lastPathComponent,
                                                        configured: excludedDirectoryNames) { return [] }
        var enqueued: [(dir: URL, display: String, depth: Int)] = [
            (URL(fileURLWithPath: resolvedRoot), baseDisplay, 0)
        ]
        while let (dir, display, depth) = enqueued.popLast() {
            var directoryStat = stat()
            guard lstat(dir.path, &directoryStat) == 0,
                  (directoryStat.st_mode & S_IFMT) == S_IFDIR else {
                continue
            }
            // An unreadable directory must not kill the whole scan (plan §42
            // doctrine): skip the subtree; the missing-sweep's errno check
            // keeps its already-indexed rows safely 'indexed'.
            let contents: [URL]
            do {
                contents = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .totalFileAllocatedSizeKey,
                ], options: [])
            } catch {
                continue
            }
            // Deterministic ordering regardless of filesystem order.
            let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in sorted {
                // Reported path: caller-dialect join. Trim a trailing slash
                // first so a bare "/" root yields "/name", never "//name".
                // Disk checks below use the REAL child.url — only the
                // spelling we emit differs.
                let parentDisplay = display.hasSuffix("/")
                    ? String(display.dropLast()) : display
                let childDisplay = parentDisplay + "/" + child.lastPathComponent
                if exclusions.contains(where: { Self.isPath(childDisplay, under: $0) }) { continue }
                if OnboardingExclusions.isExcludedDirectoryName(child.lastPathComponent,
                                                                configured: excludedDirectoryNames) { continue }
                if OnboardingExclusions.isTransientOrSystemFile(path: childDisplay) { continue }
                // lstat-level link check FIRST: a symlinked directory must be
                // recorded as a link and never descended into (plan §40).
                var lst = stat()
                guard lstat(child.path, &lst) == 0 else {
                    // A failed lstat is not evidence that a child is safe to
                    // follow. Fail closed for this entry instead of allowing
                    // FileManager metadata calls to resolve it.
                    continue
                }
                if (lst.st_mode & S_IFMT) == S_IFLNK {
                    out.append(DiscoveredItem(path: childDisplay, depth: depth))
                    continue
                }
                let vals = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isPackageKey, .isRegularFileKey])
                if vals?.isSymbolicLink == true {
                    out.append(DiscoveredItem(path: childDisplay, depth: depth))
                    continue
                }
                if vals?.isPackage == true {
                    // Opaque package: record it, never descend.
                    out.append(DiscoveredItem(path: childDisplay, depth: depth))
                    continue
                }
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: child.path, isDirectory: &isDir), isDir.boolValue {
                    if depth < maxDepth {
                        enqueued.append((child, childDisplay, depth + 1))
                    }
                    continue
                }
                out.append(DiscoveredItem(path: childDisplay, depth: depth))
            }
        }
        return out.sorted { $0.path < $1.path }
    }

    public static func isPath(_ path: String, under prefix: String) -> Bool {
        let p = prefix.count > 1 && prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix
        if p == "/" { return path.hasPrefix("/") }
        return path == p || path.hasPrefix(p + "/")
    }
}

public enum BrokerError: Error, CustomStringConvertible, Sendable {
    case statFailed(Int32)
    case openFailed(Int32)
    case isSymlink
    case notRegularFile
    case snapshotTooLarge(size: Int64, limit: Int64)
    case changedDuringRead

    public var description: String {
        switch self {
        case .statFailed(let e): return "lstat failed errno=\(e)"
        case .openFailed(let e): return "open failed errno=\(e)"
        case .isSymlink: return "refusing to open symlink"
        case .notRegularFile: return "not a regular file"
        case .snapshotTooLarge(let size, let limit):
            return "complete snapshot too large (size=\(size), limit=\(limit))"
        case .changedDuringRead:
            return "source changed during broker read"
        }
    }
}
