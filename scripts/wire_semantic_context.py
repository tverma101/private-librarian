#!/usr/bin/env python3
from pathlib import Path

smart_path = Path("Sources/LibrarianCore/Organization/SmartOrganization.swift")
smart = smart_path.read_text()
old_smart = "        let activeMemberships = try categoryMemberships(roots: roots).filter { activeIDs.contains($0.fileID) }"
new_smart = """        let activeMemberships = try semanticOrganizationMemberships(
            limit: max(384, min(2_048, activeIDs.count)), roots: roots
        ).filter { activeIDs.contains($0.fileID) }"""
if old_smart not in smart:
    raise SystemExit("SmartOrganization integration point not found")
smart_path.write_text(smart.replace(old_smart, new_smart, 1))

indexer_path = Path("Sources/LibrarianCore/Indexing/Indexer.swift")
indexer = indexer_path.read_text()
old_indexer = """        // 3b. Classify (deterministic v1 + vision labels) under MEDIUM slot.
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent,
                                visionLabels: visionLabels, screenshot: screenshotAssessment)
        }"""
new_indexer = """        // 3b. Classify cheap evidence first, then add bounded context from already
        // indexed siblings/corrections. Semantic-cluster context is also consumed
        // at organization time after the current similarity graph is refreshed.
        let semanticContext = (try? catalog.semanticResolutionContext(forFileID: id)) ?? .empty
        let classification = scheduler.perform(as: .medium) { [self] () -> Classification in
            classifier.classify(fileID: id, identity: ident, evidence: ev, textContent: textContent,
                                visionLabels: visionLabels, screenshot: screenshotAssessment,
                                semanticContext: semanticContext)
        }"""
if old_indexer not in indexer:
    raise SystemExit("Indexer integration point not found")
indexer_path.write_text(indexer.replace(old_indexer, new_indexer, 1))
