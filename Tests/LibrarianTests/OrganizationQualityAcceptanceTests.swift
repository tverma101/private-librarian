import XCTest
@testable import LibrarianCore

/// Product-level acceptance for the thing the app is actually supposed to do:
/// take a messy folder through the real Indexer + Catalog + organization planner
/// and produce useful, non-competing Finder destinations. This deliberately
/// does not inject hand-written "predicted" labels into a metric calculator.
final class OrganizationQualityAcceptanceTests: XCTestCase {
    func testRealIndexerProducesOneUsefulPrimaryDestinationPerFile() throws {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("librarian-organization-quality-\(UUID().uuidString)", isDirectory: true)
        let root = parent.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        func write(_ name: String, _ body: String) throws {
            try body.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        // Course material intentionally also looks like generic text/work. The
        // useful Finder destination is the course, not three competing folders.
        try write("MAT-171 Homework 4.txt", "MAT-171 homework 4: polynomial and rational functions")
        try write("MAT-171 Exam Review.txt", "MAT-171 exam review: functions, zeros, graphs, inequalities")

        // Generic PDFs should still fall back to the broad PDF destination.
        try write("Apartment Lease.pdf", "%PDF-1.4\nlease document alpha\n%%EOF")
        try write("Insurance Statement.pdf", "%PDF-1.4\ninsurance statement beta\n%%EOF")

        // Real source files should land together as code projects.
        try write("main.swift", "import Foundation\nfunc main() { print(\"hello\") }\n")
        try write("Utilities.swift", "import Foundation\nfunc clamp(_ x: Int) -> Int { x }\n")

        // Downloads-style installer/archive clutter should collapse into one
        // destination rather than one folder per extension.
        try write("old-export.zip", "PK synthetic archive one")
        try write("project-backup.zip", "PK synthetic archive two")

        let catalog = try TestSupport.makeCatalog()
        let indexer = Indexer(broker: SourceBroker(), catalog: catalog, scheduler: Scheduler())
        let indexed = try indexer.indexRoot(root)
        XCTAssertEqual(indexed, 8, "the acceptance corpus itself must be fully indexed")

        let groups = try catalog.smartOrganizationGroups(limit: 18, roots: [root.path])
        let destinations = groups.filter(\.canApplyToFinder)
        let rows = try catalog.allFiles(statuses: ["indexed"], roots: [root.path])
        let idByName = Dictionary(uniqueKeysWithValues: rows.map {
            ((($0.path as NSString).lastPathComponent), $0.id)
        })

        func ids(_ names: [String]) throws -> Set<String> {
            try Set(names.map { name in
                guard let id = idByName[name] else {
                    throw XCTSkip("acceptance file was not present in catalog: \(name)")
                }
                return id
            })
        }

        let mathIDs = try ids(["MAT-171 Homework 4.txt", "MAT-171 Exam Review.txt"])
        let pdfIDs = try ids(["Apartment Lease.pdf", "Insurance Statement.pdf"])
        let codeIDs = try ids(["main.swift", "Utilities.swift"])
        let archiveIDs = try ids(["old-export.zip", "project-backup.zip"])

        XCTAssertEqual(Set(destinations.first { $0.title == "MAT-171" }?.fileIDs ?? []), mathIDs)
        XCTAssertEqual(Set(destinations.first { $0.title == "PDFs" }?.fileIDs ?? []), pdfIDs)
        XCTAssertEqual(Set(destinations.first { $0.title == "Code projects" }?.fileIDs ?? []), codeIDs)
        XCTAssertEqual(Set(destinations.first { $0.title == "Installers & archives" }?.fileIDs ?? []), archiveIDs)

        // This is the critical product invariant: a file may have many evidence
        // labels, but the app must not offer multiple contradictory Finder moves.
        var destinationCountByFile: [String: Int] = [:]
        for group in destinations {
            for fileID in group.fileIDs {
                destinationCountByFile[fileID, default: 0] += 1
            }
        }
        XCTAssertTrue(destinationCountByFile.values.allSatisfy { $0 == 1 },
                      "a file appeared in competing Finder destinations: \(destinationCountByFile)")

        XCTAssertFalse(destinations.contains { $0.title == "Assignments" && !$0.fileIDs.isDisjoint(with: mathIDs) },
                       "course files must not simultaneously be offered as an Assignments move")
        XCTAssertFalse(destinations.contains { $0.title == "PDFs" && !$0.fileIDs.isDisjoint(with: mathIDs) },
                       "course files must not simultaneously be offered as a PDFs move")
    }
}

private extension Array where Element == String {
    func isDisjoint(with other: Set<String>) -> Bool {
        Set(self).isDisjoint(with: other)
    }
}
