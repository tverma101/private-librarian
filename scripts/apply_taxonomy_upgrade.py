#!/usr/bin/env python3
from pathlib import Path

path = Path("Sources/LibrarianCore/Indexer.swift")
text = path.read_text()
old = '''        if !similarityChangedIDs.isEmpty || !similarityRemovedIDs.isEmpty {\n            try? rebuildSimilarityGraph(changedFileIDs: similarityChangedIDs,\n                                        removedFileIDs: similarityRemovedIDs)\n        }\n        return actuallyProcessed\n'''
new = '''        if !similarityChangedIDs.isEmpty || !similarityRemovedIDs.isEmpty {\n            try? rebuildSimilarityGraph(changedFileIDs: similarityChangedIDs,\n                                        removedFileIDs: similarityRemovedIDs)\n        }\n        // Classification revisions can retire old taxonomy leaves. Once all\n        // memberships for this pass are current, remove catalog-only category\n        // nodes that no longer lead to any file. Originals are never touched.\n        try? catalog.pruneUnusedVirtualCategories()\n        return actuallyProcessed\n'''
count = text.count(old)
if count != 1:
    raise SystemExit(f"Indexer.swift: expected one indexRoot tail, found {count}")
path.write_text(text.replace(old, new, 1))
print("taxonomy upgrade patch applied")
