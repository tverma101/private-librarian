import Foundation
import XCTest
@testable import LibrarianCore

final class BoundedViewQueryTests: XCTestCase {
    func testScopedViewsStayInsideSelectedRoot() throws {
        let catalog = try TestSupport.makeCatalog()
        let now = Date().timeIntervalSince1970

        try catalog.transaction {
            let csc = try catalog.txEnsureCategory(named: "School/CSC-151")
            let mat = try catalog.txEnsureCategory(named: "School/MAT-171")
            for (index, row) in [
                ("a1", "/alpha/one.txt", csc),
                ("a2", "/alpha/two.txt", csc),
                ("b1", "/beta/one.txt", mat),
                ("b2", "/beta/two.txt", mat),
            ].enumerated() {
                try catalog.txRun("""
                    INSERT INTO files(id,path,volume_uuid,fs_file_id,size,mtime,ctime,kind,is_symlink,status,first_seen,last_indexed)
                    VALUES(?,?,?,?,?,?,?,?,0,'indexed',?,?)
                    """, binds: [
                        .text(row.0), .text(row.1), .null, .int(Int64(index + 1)), .int(16),
                        .real(now), .real(now), .text(FileKind.text.rawValue), .real(now), .real(now)
                    ])
                try catalog.txRun(
                    "INSERT INTO category_membership(category_id,file_id,source) VALUES(?,?,'classifier')",
                    binds: [.int(row.2), .text(row.0)])
            }
        }

        let scopedFiles = try catalog.boundedFileSummaries(roots: ["/alpha"], limit: 20)
        XCTAssertEqual(scopedFiles.map(\.path), ["/alpha/one.txt", "/alpha/two.txt"])

        let scopedDashboard = try catalog.dashboard(roots: ["/alpha"])
        XCTAssertEqual(scopedDashboard.total, 2)
        XCTAssertEqual(scopedDashboard.indexed, 2)

        let scopedGroups = try catalog.smartOrganizationGroups(roots: ["/alpha"])
        XCTAssertTrue(scopedGroups.contains(where: { $0.title == "CSC-151" }))
        XCTAssertFalse(scopedGroups.contains(where: { $0.title == "MAT-171" }))
        XCTAssertTrue(scopedGroups.allSatisfy { $0.fileIDs.allSatisfy { ["a1", "a2"].contains($0) } })
    }

    func testLargeCatalogViewsFilterAndPageInSQL() throws {
        let catalog = try TestSupport.makeCatalog()
        let total = 5_000
        let now = Date().timeIntervalSince1970

        try catalog.transaction {
            let schoolCategory = try catalog.txEnsureCategory(named: "School/MAT-171")
            for index in 0..<total {
                let id = "view-scale-\(index)"
                let path = String(format: "/repo/src/%05d.dat", index)
                let kind: String
                if index >= total - 10 {
                    kind = index.isMultiple(of: 2) ? FileKind.audio.rawValue : FileKind.video.rawValue
                } else {
                    kind = FileKind.text.rawValue
                }
                try catalog.txRun("""
                    INSERT INTO files(id,path,volume_uuid,fs_file_id,size,mtime,ctime,kind,is_symlink,status,first_seen,last_indexed)
                    VALUES(?,?,?,?,?,?,?,?,0,'indexed',?,?)
                    """, binds: [
                        .text(id), .text(path), .null, .int(Int64(index + 1)), .int(32),
                        .real(now), .real(now), .text(kind), .real(now), .real(now)
                    ])

                if index >= total - 20 {
                    try catalog.txRun(
                        "INSERT OR IGNORE INTO category_membership(category_id,file_id,source) VALUES(?,?,'classifier')",
                        binds: [.int(schoolCategory), .text(id)])
                }
                if index >= total - 6 {
                    try catalog.txRun(
                        "INSERT INTO exact_hashes(file_id,size,sha256,computed) VALUES(?,?,?,?)",
                        binds: [.text(id), .int(32), .blob(Data([0xFA, 0xCE])), .real(now)])
                }
            }
        }

        let media = try catalog.boundedFileSummaries(kinds: [.audio, .video], limit: 5)
        XCTAssertEqual(media.count, 5)
        XCTAssertTrue(media.allSatisfy {
            $0.kind == FileKind.audio.rawValue || $0.kind == FileKind.video.rawValue
        })
        XCTAssertTrue(media.allSatisfy { $0.path >= "/repo/src/04990.dat" })

        let duplicates = try catalog.boundedFileSummaries(duplicateOnly: true, limit: 4)
        XCTAssertEqual(duplicates.count, 4)
        XCTAssertTrue(duplicates.allSatisfy { $0.path >= "/repo/src/04994.dat" })

        let school = try catalog.boundedFileSummaries(categoryPrefix: "School", limit: 7)
        XCTAssertEqual(school.count, 7)
        XCTAssertTrue(school.allSatisfy { $0.path >= "/repo/src/04980.dat" })

        let firstPage = try catalog.boundedFileSummaries(limit: 200)
        XCTAssertEqual(firstPage.count, 200)
        let cursor = try XCTUnwrap(firstPage.last?.path)
        let secondPage = try catalog.boundedFileSummaries(afterPath: cursor, limit: 200)
        XCTAssertEqual(secondPage.count, 200)
        XCTAssertTrue(secondPage.allSatisfy { $0.path > cursor })
        XCTAssertTrue(Set(firstPage.map(\.id)).isDisjoint(with: Set(secondPage.map(\.id))))
    }

    func testScopedSimilarityPageReturnsEachClusterOnce() throws {
        let catalog = try TestSupport.makeCatalog()
        let now = Date()
        for (index, id) in ["cluster-a", "cluster-b", "cluster-c"].enumerated() {
            try catalog.upsertFile(
                identity: FileIdentity(
                    path: "/alpha/\(id).txt", volumeUUID: nil,
                    fileID: UInt64(index + 1), size: 4,
                    mtime: now, ctime: now, kind: .text, isSymlink: false),
                id: id)
            try catalog.setStatus(fileID: id, status: "indexed")
        }
        try catalog.replaceSimilarityGraph(SimilarityGraphUpdate(
            edges: [],
            clusters: [SimilarityCluster(
                id: "cluster-alpha", members: ["cluster-a", "cluster-b", "cluster-c"],
                representative: "cluster-a", relation: .nearDuplicate)]))

        let page = try catalog.boundedSimilarityClusters(roots: ["/alpha"], limit: 10)
        XCTAssertEqual(page.count, 1)
        XCTAssertEqual(page.first?.members, ["cluster-a", "cluster-b", "cluster-c"])
    }
}
