import Foundation

/// Coarse content kind used for routing to workers. Derived from UTType,
/// never from trusting extensions alone.
public enum FileKind: String, Codable, Sendable {
    case image
    case audio
    case video
    case pdf
    case text          // txt / md / source code / config
    case office        // docx / xlsx / pptx (ZIP/XML containers)
    case archive       // zip / tar / 7z / rar / iso — metadata only
    case diskImage
    case application   // .app bundles
    case package       // .photoslibrary, .bundle, .framework, ...
    case symlink
    case other
}

/// Immutable identity snapshot of a source file, taken BEFORE processing.
/// Used for race detection: re-stat immediately before committing analysis.
public struct FileIdentity: Codable, Sendable, Equatable {
    public let path: String
    public let volumeUUID: String?
    public let fileID: UInt64        // st_ino on APFS/HFS+
    public let size: Int64
    public let mtime: Date
    public let ctime: Date
    public let kind: FileKind
    public let isSymlink: Bool

    /// True when a fresh stat still matches this identity.
    public func stillMatches(_ now: FileIdentity) -> Bool {
        return path == now.path
            && volumeUUID == now.volumeUUID
            && fileID == now.fileID
            && size == now.size
            && mtime == now.mtime
            && kind == now.kind
            && isSymlink == now.isSymlink
    }
}
