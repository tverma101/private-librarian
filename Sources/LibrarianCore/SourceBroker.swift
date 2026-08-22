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

    public init(maxReadBytes: Int64 = 8 * 1024 * 1024, hugeFileThreshold: Int64 = 2 * 1024 * 1024 * 1024) {
        self.maxReadBytes = maxReadBytes
        self.hugeFileThreshold = hugeFileThreshold
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
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ELOOP { throw BrokerError.isSymlink }
            throw BrokerError.openFailed(errno)
        }
        // Confirm what we opened is a regular file (defends against FIFOs,
        // devices, and TOCTOU swaps between lstat and open).
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw BrokerError.notRegularFile
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
                if got <= 0 { break }
                data.append(contentsOf: UnsafeBufferPointer(start: chunk, count: got))
                remaining -= Int64(got)
            }
            return data
        }
    }

    /// Read exactly `length` bytes starting at `offset` without moving a shared
    /// cursor (pread). Bounded by maxReadBytes. Strictly read-only.
    public func readSlice(path: String, offset: Int64, length: Int64) throws -> Data {
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
                if got <= 0 { break }
                data.append(contentsOf: UnsafeBufferPointer(start: chunk, count: got))
                off += Int64(got)
                remaining -= Int64(got)
            }
            return data
        }
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
    public static func enumerate(root: URL, maxDepth: Int = 16) throws -> [DiscoveredItem] {
        var out: [DiscoveredItem] = []
        let fm = FileManager.default
        var baseDisplay = root.path
        if baseDisplay.hasSuffix("/") && baseDisplay.count > 1 { baseDisplay = String(baseDisplay.dropLast()) }
        var enqueued: [(dir: URL, display: String, depth: Int)] = [(root, baseDisplay, 0)]
        while let (dir, display, depth) = enqueued.popLast() {
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
                // lstat-level link check FIRST: a symlinked directory must be
                // recorded as a link and never descended into (plan §40).
                var lst = stat()
                if lstat(child.path, &lst) == 0, (lst.st_mode & S_IFMT) == S_IFLNK {
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
}

public enum BrokerError: Error, CustomStringConvertible, Sendable {
    case statFailed(Int32)
    case openFailed(Int32)
    case isSymlink
    case notRegularFile

    public var description: String {
        switch self {
        case .statFailed(let e): return "lstat failed errno=\(e)"
        case .openFailed(let e): return "open failed errno=\(e)"
        case .isSymlink: return "refusing to open symlink"
        case .notRegularFile: return "not a regular file"
        }
    }
}
