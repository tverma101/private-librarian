import XCTest
@testable import LibrarianCore

final class SmartOrganizationStressTests: XCTestCase {
    func testThousandsOfNoisySignalsStillProduceSmallDiverseUsefulGroups() {
        var memberships: [(categoryPath: String, fileID: String)] = []

        // Model/evidence noise: five thousand one-off labels must never become
        // five thousand user-facing pseudo-folders.
        for index in 0..<5_000 {
            memberships.append(("Image/Raw-Model-Label-\(index)", "noise-\(index)"))
        }

        // Useful broad signals with real support.
        let courseCodes = [
            "MAT-171", "CSC-151", "ENG-112", "BIO-110", "PSY-150",
            "COM-120", "HIS-111", "ART-111", "PHY-151", "CHM-151"
        ]
        for course in courseCodes {
            for item in 0..<8 {
                memberships.append(("School/\(course)", "course-\(course)-\(item)"))
            }
        }
        for subtype in ["code", "school", "lms", "receipt", "error", "conversation", "social", "map"] {
            for item in 0..<6 {
                memberships.append(("Screenshots/\(subtype)", "shot-\(subtype)-\(item)"))
            }
        }
        for item in 0..<120 {
            memberships.append(("Projects/Code", "project-\(item)"))
        }
        for item in 0..<80 {
            memberships.append(("Documents/PDF", "pdf-\(item)"))
        }
        for item in 0..<60 {
            memberships.append(("Image/Animals", "animal-\(item)"))
        }

        var clusters: [SimilarityCluster] = []
        for index in 0..<100 {
            clusters.append(SimilarityCluster(
                id: "dup-\(index)",
                members: ["dup-\(index)-a", "dup-\(index)-b"],
                representative: "dup-\(index)-a",
                relation: .nearDuplicate,
                familyID: "dup-family-\(index)",
                confidence: 0.99,
                reason: "synthetic near duplicate"
            ))
        }
        for index in 0..<50 {
            clusters.append(SimilarityCluster(
                id: "semantic-\(index)",
                members: ["semantic-\(index)-a", "semantic-\(index)-b", "semantic-\(index)-c"],
                representative: "semantic-\(index)-a",
                relation: .semantic,
                familyID: "semantic-family-\(index)",
                confidence: 0.90,
                reason: "synthetic semantic family"
            ))
        }

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: clusters
        )

        XCTAssertLessThanOrEqual(groups.count, 18, "Smart Groups must remain a small dashboard, not a generated folder tree")
        XCTAssertTrue(groups.allSatisfy { $0.fileIDs.count >= 2 }, "singleton groups must never be promoted")
        XCTAssertFalse(groups.contains { $0.id.contains("Raw-Model-Label") }, "raw model-label noise leaked into the product surface")

        let duplicateCount = groups.filter { $0.kind == .nearDuplicate }.count
        let semanticCount = groups.filter { $0.kind == .semantic }.count
        let screenshotCount = groups.filter { $0.id.hasPrefix("category:Screenshots/") }.count
        let schoolCount = groups.filter { $0.id.hasPrefix("category:School/") }.count
        let projectCount = groups.filter { $0.id.hasPrefix("category:Projects/") }.count

        XCTAssertLessThanOrEqual(duplicateCount, 3, "duplicate families monopolized Smart Groups")
        XCTAssertLessThanOrEqual(semanticCount, 5, "semantic families monopolized Smart Groups")
        XCTAssertLessThanOrEqual(screenshotCount, 4, "screenshot subtypes monopolized Smart Groups")
        XCTAssertLessThanOrEqual(schoolCount, 4, "course groups monopolized Smart Groups")
        XCTAssertLessThanOrEqual(projectCount, 2, "project groups monopolized Smart Groups")

        XCTAssertTrue(groups.contains { $0.id == "category:Projects/Code" }, "high-support project group was crowded out")
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:School/") }, "school signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.id.hasPrefix("category:Screenshots/") }, "screenshot signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.kind == .nearDuplicate }, "duplicate signal disappeared under noise")
        XCTAssertTrue(groups.contains { $0.kind == .semantic }, "semantic signal disappeared under noise")

        let representedLanes = Set(groups.map { group -> String in
            if group.kind == .nearDuplicate { return "duplicates" }
            if group.kind == .semantic { return "semantic" }
            if group.id.hasPrefix("category:Screenshots/") { return "screenshots" }
            if group.id.hasPrefix("category:School/") { return "school" }
            if group.id.hasPrefix("category:Projects/") { return "projects" }
            return "general"
        })
        XCTAssertGreaterThanOrEqual(representedLanes.count, 5, "Smart Groups lost useful diversity: \(representedLanes)")
    }

    func testRepeatedMalformedTaxonomyCannotBecomePolishedSmartGroups() {
        let malformed = [
            "School/banana",
            "School/💥💥💥",
            "School/mat-171",
            "School/MAT\u{2011}171",       // Unicode non-breaking hyphen
            "School/MAT-17",
            "School/MAT-171/extra",
            "School/\u{202E}171-TAM",     // bidi control/spoof-looking text
            "School/" + String(repeating: "A", count: 4_096),
            "Screenshots/banana",
            "Screenshots/CODE",
            "Screenshots/code\u{0000}",
            "Screenshots/../../evil",
            "Screenshots/receipt/extra",
            "Screenshots/🤖"
        ]

        var memberships: [(categoryPath: String, fileID: String)] = []
        for (labelIndex, label) in malformed.enumerated() {
            for item in 0..<12 {
                memberships.append((label, "poison-\(labelIndex)-\(item)"))
            }
        }

        // Benign formatting noise should collapse to the same canonical path,
        // while the actual taxonomy still has to be valid.
        memberships += [
            ("School/MAT-171", "math-a"),
            (" School // MAT-171 ", "math-b"),
            ("Screenshots/code", "code-a"),
            (" Screenshots // code ", "code-b")
        ]

        let groups = SmartOrganizationPlanner(maxGroups: 18).build(
            memberships: memberships,
            similarityClusters: [])

        XCTAssertEqual(Set(groups.map(\.id)), [
            "category:School/MAT-171",
            "category:Screenshots/code"
        ])
        XCTAssertEqual(groups.first(where: { $0.id == "category:School/MAT-171" })?.fileIDs.count, 2)
        XCTAssertEqual(groups.first(where: { $0.id == "category:Screenshots/code" })?.fileIDs.count, 2)
        XCTAssertFalse(groups.contains { group in
            malformed.contains { bad in group.id.contains(bad) || group.title.contains(bad) }
        })
    }

    func testWeirdRealParentFolderNamesDoNotInventVirtualCategories() {
        let identity = FileIdentity(
            path: "/tmp/💀 FINAL final v7/School/banana/随机/ordinary.txt",
            volumeUUID: nil,
            fileID: 7,
            size: 128,
            mtime: Date(),
            ctime: Date(),
            kind: .text,
            isSymlink: false
        )
        var evidence = EvidenceExtractor.Evidence()
        evidence.kind = FileKind.text.rawValue
        evidence.sizeClass = "small"
        evidence.filenameTokens = ["ordinary"]

        let result = RuleBasedClassifier().classify(
            fileID: "weird-parent",
            identity: identity,
            evidence: evidence,
            textContent: "plain notes with no course code or organization keyword"
        )

        XCTAssertTrue(result.categories.contains("Documents/Text"))
        XCTAssertFalse(result.categories.contains(where: {
            $0.contains("banana") || $0.contains("随机") || $0.contains("FINAL")
        }))
        XCTAssertFalse(result.categories.contains(where: { $0.hasPrefix("School/") }))
    }

    func testProgrammingAndEnglishWordsDoNotMasqueradeAsSchoolOrScreenshotEvidence() {
        func classify(path: String, tokens: [String], text: String) -> Classification {
            let identity = FileIdentity(
                path: path,
                volumeUUID: nil,
                fileID: UInt64(abs(path.hashValue)),
                size: 512,
                mtime: Date(),
                ctime: Date(),
                kind: .text,
                isSymlink: false
            )
            var evidence = EvidenceExtractor.Evidence()
            evidence.kind = FileKind.text.rawValue
            evidence.sizeClass = "small"
            evidence.filenameTokens = tokens
            return RuleBasedClassifier().classify(
                fileID: "collision-test",
                identity: identity,
                evidence: evidence,
                textContent: text
            )
        }

        let code = classify(
            path: "/tmp/CanvasRenderer.swift",
            tokens: ["canvas", "renderer"],
            text: "let canvas = Renderer(); let assignment = node; let screenshot = snapshot()"
        )
        XCTAssertTrue(code.categories.contains("Projects/Code"))
        XCTAssertFalse(code.categories.contains("School"))
        XCTAssertFalse(code.categories.contains("Assignment"))
        XCTAssertFalse(code.categories.contains("Screenshot"))

        let material = classify(
            path: "/tmp/material-design-notes.txt",
            tokens: ["material", "design", "notes"],
            text: "material design matrix rendering notes"
        )
        XCTAssertFalse(material.categories.contains("School"))
        XCTAssertFalse(material.categories.contains(where: { $0.hasPrefix("School/") }))

        let courseFilename = classify(
            path: "/tmp/MAT171_final.txt",
            tokens: ["mat171", "final"],
            text: "ordinary review notes"
        )
        XCTAssertTrue(courseFilename.categories.contains("School/MAT-171"))

        let lms = classify(
            path: "/tmp/course-notes.txt",
            tokens: ["course", "notes"],
            text: "Canvas course module assignment due Friday"
        )
        XCTAssertTrue(lms.categories.contains("School"))
        XCTAssertTrue(lms.categories.contains("Assignment"))
    }
}
