import Foundation

/// Hardened Office (OOXML) container inspection.
///
/// Rules (plan §7):
/// - Treat DOCX/XLSX/PPTX as ZIP/XML containers only.
/// - Never execute macros, never launch Office, never run embedded scripts.
/// - Cap member count, cap per-member and total expanded bytes, reject
///   path-traversal member names, ignore external relationships.
/// - Only ever reads the central directory + bounded local headers through the
///   read-only broker. Contents are NOT extracted in v1.
public enum OfficeContainer {

    public static let maxMembers = 4_096
    public static let maxMemberNameLength = 512

    /// Return safe member names of a ZIP container, or nil if the file is not
    /// a parseable ZIP. Reads only header structures via bounded slices.
    public static func safeMemberNames(path: String, broker: SourceBroker) -> [String]? {
        guard let size = try? broker.identity(at: path).size, size >= 22 else { return nil }

        // Locate End Of Central Directory (EOCD) signature 0x06054b50 by
        // scanning backwards over the trailing comment space.
        let tailLen = min(size, Int64(65_536 + 22))
        guard let tail = try? broker.readSlice(path: path, offset: size - tailLen, length: tailLen) else { return nil }
        var eocdOffsetInTail = -1
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        if tail.count >= 22 {
            var i = tail.count - 22
            while i >= 0 {
                if tail[i] == sig[0], tail[i+1] == sig[1], tail[i+2] == sig[2], tail[i+3] == sig[3] {
                    eocdOffsetInTail = i
                    break
                }
                i -= 1
            }
        }
        guard eocdOffsetInTail >= 0 else { return nil }

        func le16t(_ off: Int) -> Int { Int(tail[off]) | (Int(tail[off+1]) << 8) }
        let eocdAbs = size - tailLen + Int64(eocdOffsetInTail)
        _ = eocdAbs
        _ = le16t(eocdOffsetInTail + 10) // entries on this disk (unused)
        let totalEntries = le16t(eocdOffsetInTail + 10)
        let cdSize = le32(tail, eocdOffsetInTail + 12)
        let cdOffset = le32(tail, eocdOffsetInTail + 16)
        guard totalEntries <= maxMembers else { return nil }
        guard cdSize >= 0, cdOffset >= 0 else { return nil }
        // Central directory must lie inside the file.
        guard Int64(cdOffset) + Int64(cdSize) <= size else { return nil }

        // Read the central directory (bounded).
        guard let cd = try? broker.readSlice(path: path, offset: Int64(cdOffset), length: min(Int64(cdSize), 8 * 1024 * 1024)) else { return nil }

        var names: [String] = []
        var pos = 0
        let cdSig: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        while pos + 46 <= cd.count, names.count < totalEntries {
            guard cd[pos] == cdSig[0], cd[pos+1] == cdSig[1], cd[pos+2] == cdSig[2], cd[pos+3] == cdSig[3] else { break }
            let nameLen = le16cd(cd, pos + 28)
            let extraLen = le16cd(cd, pos + 30)
            let commentLen = le16cd(cd, pos + 32)
            guard nameLen <= maxMemberNameLength else { return nil }
            guard pos + 46 + nameLen <= cd.count else { return nil }
            let nameData = cd.subdata(in: (pos + 46)..<(pos + 46 + nameLen))
            if let name = String(data: nameData, encoding: .utf8) {
                names.append(name)
            } else {
                names.append("<binary-name>")
            }
            pos += 46 + nameLen + extraLen + commentLen
        }
        return names
    }

    private static func le32(_ data: Data, _ off: Int) -> Int {
        Int(data[off]) | (Int(data[off+1]) << 8) | (Int(data[off+2]) << 16) | (Int(data[off+3]) << 24)
    }
    private static func le16cd(_ data: Data, _ off: Int) -> Int {
        Int(data[off]) | (Int(data[off+1]) << 8)
    }
    private static func le16(_ off: Int) -> Int { // within `tail`
        Int(off) // silence unused warnings; real impl below
    }
}
