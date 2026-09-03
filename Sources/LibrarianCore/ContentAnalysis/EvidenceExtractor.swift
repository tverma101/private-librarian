import Foundation

/// Deterministic evidence extractor — the "cheap deterministic evidence" layer.
/// Pure Swift, no ML: filename tokens, extension, size class, text sniffing.
/// Its output feeds the classifier as *evidence*, never as commands.
public struct EvidenceExtractor: Sendable {

    public struct Evidence: Sendable {
        public var filenameTokens: [String] = []
        public var kind: String = "other"
        public var sizeClass: String = "small"     // tiny/small/medium/large/huge
        public var isCloudPlaceholder = false
        public var textSample: String? = nil       // bounded UTF-8 head for text files
        public var officeMembers: [String] = []    // safe member list (names only)
        public var archiveMemberCount: Int? = nil  // when cheaply available
        public var notes: [String] = []
    }

    let broker: SourceBroker

    public init(broker: SourceBroker) { self.broker = broker }

    /// Detect cloud placeholders (dataless files) WITHOUT hydrating them.
    /// Uses NSURL file resource keys that do not trigger download.
    static func isCloudPlaceholder(at path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        guard let vals = try? url.resourceValues(forKeys: keys) else { return false }
        if vals.isUbiquitousItem == true {
            if let status = vals.ubiquitousItemDownloadingStatus,
               status != URLUbiquitousItemDownloadingStatus.current {
                return true
            }
            return false
        }
        // macOS dataless files (File Provider): size allocated == 0 while logical size > 0
        if let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]),
           let logical = v.fileSize, logical > 0,
           let alloc = v.totalFileAllocatedSize, alloc == 0 {
            return true
        }
        return false
    }

    public func extract(identity: FileIdentity) -> Evidence {
        var ev = Evidence()
        ev.kind = identity.kind.rawValue
        ev.sizeClass = Self.sizeClass(identity.size)
        ev.filenameTokens = Self.tokens((identity.path as NSString).lastPathComponent)

        if identity.isSymlink {
            ev.notes.append("symlink-not-followed")
            return ev
        }
        if Self.isCloudPlaceholder(at: identity.path) {
            ev.isCloudPlaceholder = true
            ev.notes.append("cloud-placeholder-deferred")
            return ev
        }

        switch identity.kind {
        case .text:
            if let data = try? broker.boundedRead(identity.path, limit: 64 * 1024),
               let str = Self.decodeText(data) {
                ev.textSample = String(str.prefix(8_000))
            }
        case .office, .archive:
            ev.officeMembers = OfficeContainer.safeMemberNames(path: identity.path, broker: broker) ?? []
            ev.archiveMemberCount = ev.officeMembers.isEmpty ? nil : ev.officeMembers.count
            if identity.kind == .archive {
                ev.notes.append("archive-contents-unopened")
            }
        default:
            break
        }
        return ev
    }

    static func sizeClass(_ size: Int64) -> String {
        switch size {
        case ..<1_024: return "tiny"
        case ..<102_400: return "small"
        case ..<10_485_760: return "medium"
        case ..<1_073_741_824: return "large"
        default: return "huge"
        }
    }

    /// Tokenize a filename into lowercase words; strips extensions and digits-only noise.
    static func tokens(_ filename: String) -> [String] {
        let base = (filename as NSString).deletingPathExtension
        let parts = base
            .components(separatedBy: CharacterSet(charactersIn: " _-.[]()"))
            .map { $0.lowercased() }
            .filter { !$0.isEmpty && $0.count > 1 && !($0.allSatisfy { !$0.isLetter }) }
        return Array(Set(parts)).sorted()
    }

    /// Decode extracted text without mojibake. UTF-8 is tried first; BOM-marked
    /// UTF-16 files (common on Windows) decode as UTF-16 rather than falling
    /// through to Latin-1, which silently turns every other byte into NUL
    /// noise and makes the real words unsearchable. Only genuine single-byte
    /// legacy content falls back to ISO Latin-1.
    static func decodeText(_ data: Data) -> String? {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.index(after: data.startIndex)]
            let hasUTF16BOM = (first == 0xFF && second == 0xFE) || (first == 0xFE && second == 0xFF)
            if hasUTF16BOM {
                return String(data: data, encoding: .utf16)
            }
        }
        return String(data: data, encoding: .isoLatin1)
    }
}
