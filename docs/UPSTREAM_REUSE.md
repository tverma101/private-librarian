# Upstream references and adaptation notes

Private Librarian reuses ideas from existing open-source work where that saves time, but keeps its own source-safety boundary: originals stay read-only, organization stays virtual, and models do not receive source filesystem authority.

This page records the important upstream references and what was adapted, studied, or deliberately not copied.

## FileID

Repository: `WebWorldWide/FileID`

Useful areas studied:

- identity/similarity clustering;
- semantic restructure scoring and confidence ideas;
- review/feedback presentation;
- cluster suggestion UI;
- local CLIP runtime and text-encoder patterns.

What is useful to adapt:

- connected-component and cluster-representative ideas;
- confidence/review bands;
- warm model-session reuse;
- preprocessing/dimension checks;
- bounded concurrency;
- presentation ideas for clusters and review queues.

What is **not** imported into Private Librarian:

- applying a restructure to real folders;
- moving, renaming, deleting, or tagging source files;
- any model/runtime API that would bypass `SourceBroker` and reopen an original independently.

FileID's Apple `MobileCLIPService.swift` was treated as an OpenCLIP/ViT-B/32-style runtime reference rather than proof that the code was using Apple's genuine MobileCLIP model family. Provider identity is verified from the actual implementation/artifacts rather than inferred from a class name.

## swift-mobileclip

Repository: `sfomuseum/swift-mobileclip`

This project was used as a direct reference for genuine MobileCLIP model/tokenizer behavior.

Private Librarian's local tokenizer implementation follows the CLIP BPE/byte-encoding contract from that BSD-licensed reference. The source file identifies that adaptation, and the required BSD notice is retained in:

`ThirdParty/SWIFT_MOBILECLIP_LICENSE.md`

Private Librarian keeps its own provider/preflight/provenance layer and does not add a runtime network dependency on the upstream package.

## SQLCipher

SQLCipher is vendored as an amalgamation under `ThirdParty/sqlcipher/` so the catalog does not silently fall back to the system SQLite library without encryption support.

The repository keeps:

- `LICENSE_SQLCIPHER.md`;
- `LICENSE_SQLITE.md`;
- `PROVENANCE.md`;
- the vendored source/header files used by the SwiftPM target.

CI checks the expected provenance files as part of the normal build.

## Capability-by-capability decisions

| Area | Upstream input | Decision |
|---|---|---|
| Screenshot intelligence | Apple Vision + confidence/review ideas from FileID | Build locally; use broker bytes and catalog-only output |
| Similarity families | FileID clustering/restructure techniques | Adapt clustering ideas; keep explicit virtual near-duplicate/semantic relations |
| Organization graph | FileID relation/presentation ideas | Build locally in the encrypted catalog |
| Review Inbox | FileID feedback/review UX ideas | Adapt interaction concepts; corrections remain catalog-only |
| Golden Library quality checks | General labeled-fixture/quality-test patterns | Build locally with synthetic fixtures and explicit provider identity |
| Decoder-safe complete snapshots | No upstream source authority adopted | Build locally around `SourceBroker` |
| Whole-computer onboarding | General authorized-root UX patterns | Build locally with read-only security-scoped bookmarks |
| Dashboard / cluster explorer | FileID restructure presentation ideas | Study/adapt presentation only; no apply/restructure action |
| Native image/text embeddings | FileID runtime techniques + genuine `swift-mobileclip` reference | Keep providers separate and benchmark exact implementations |
| Local ASR/media | Local decoder/ASR patterns | Build locally; ASR receives PCM, not source paths |
| Live indexing | Apple FSEvents | Build locally; observe authorized roots only |
| Learned rules | Feedback/evidence concepts | Build locally with inspectable, reversible, evidence-bound rules |

## Rules for future upstream reuse

Before copying or porting code:

1. Verify what the upstream implementation actually does; do not trust filenames or marketing names.
2. Check the license and keep any required copyright/notice text.
3. Prefer small, attributable adaptations over copying a large subsystem that brings unrelated behavior.
4. Keep `SourceBroker`, encrypted catalog state, incremental invalidation, and virtual-only organization as the local architecture boundary.
5. Add a fixture or benchmark that proves the adaptation is useful before making it the default.
6. Record model/checkpoint/preprocessing identity when model output depends on it.

Unlicensed/no-license repositories may still be useful research references, but their code should be treated as reference-only unless permission is obtained.

## Current provider position

The repository supports a backend-neutral embedding interface. Genuine Core ML MobileCLIP is implemented as an optional local provider, while the Python-backed path remains a comparison/fallback when its artifacts and dependencies are actually provisioned.

No provider should become the default from theoretical speed or naming alone. Runtime measurements and Golden Library retrieval quality should be compared on the same fixture first.
