# Upstream-first roadmap audit

Issue #38 is a research/planning deliverable. This matrix verifies the
implementation identity of the useful upstream references and keeps their
filesystem-mutating behavior outside Private Librarian. The audit was run
against the pinned local checkouts of FileID and `sfomuseum/swift-mobileclip`;
the URLs below are the reviewable upstream sources.

Private Librarian remains canonical for `SourceBroker`, SQLCipher, incremental
identity/generation checks, bytes-only model inputs, and virtual-only catalog
organization. No row below authorizes moving, renaming, deleting, tagging, or
rewriting an original.

| Issue | Capability | Upstream reference(s) | Decision | Exact techniques/files worth borrowing | Private Librarian boundary | Required proof before integration |
|---|---|---|---|---|---|---|
| #23 | Screenshot intelligence | Apple Vision; FileID restructure confidence ideas in [`shared/docs/RESTRUCTURE.md`](https://github.com/WebWorldWide/FileID/blob/main/shared/docs/RESTRUCTURE.md) | BUILD OURSELVES / STUDY | `VNImageRequestHandler(data:)`; FileID cluster-profile/review-band concepts | Screenshot evidence consumes broker bytes and writes only encrypted assessment/memberships; no source rename or model-specific contract | 8+ subtype fixtures plus non-screenshot controls, reason codes, OCR/search, unchanged skip, no source diff |
| #24 | Near-duplicate and semantic families | FileID [`pipeline/identity_clustering.rs`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/engine/Sources/FileIDEngine/Pipeline/IdentityClustering.swift), [`pipeline/RestructureSemantic.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/engine/Sources/FileIDEngine/Pipeline/RestructureSemantic.swift), and [`shared/docs/RESTRUCTURE.md`](https://github.com/WebWorldWide/FileID/blob/main/shared/docs/RESTRUCTURE.md) | ADAPT | Connected components, feature fusion, confidence tiers, representative/medoid ideas | Keep explicit `nearDuplicate` vs `semantic` relations, provider-neutral spaces, SQLCipher graph, virtual membership only | Crops/resizes/screenshot-of-screenshot/lookalike/semantic-sibling fixture; separate precision/recall and purity/completeness; incremental neighborhood benchmark |
| #25 | Organization graph and multi-label views | FileID restructure data flow and [`ClusterSuggestions.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Database/ClusterSuggestions.swift) | BUILD OURSELVES | Stable graph/node identifiers and derived relation presentation | Catalog rows/edges are encrypted and virtual; deleting a relation cannot touch a source | Multi-label fixture, deterministic query order, migration test, relation-query latency at 10k/100k |
| #26 | Review inbox and uncertainty routing | FileID [`RestructureFeedback.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/engine/Sources/FileIDEngine/Pipeline/RestructureFeedback.swift), [`RestructureRecommendationRow.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Views/Restructure/RestructureRecommendationRow.swift) | ADAPT | Confidence/reason display, accept/reject/hold routing, correction feedback | Corrections are catalog-only overrides and learning evidence; no apply/restructure/move action | Ambiguous vs high-confidence fixture, one-interaction resolution, restart/re-index persistence, review precision/coverage |
| #27 | Golden Library quality metrics | FileID [`RestructureQualityQueryTests.cs`](https://github.com/WebWorldWide/FileID/blob/main/platforms/windows/Tests/FileID.App.Tests/RestructureQualityQueryTests.cs) as a quality-test reference | BUILD OURSELVES | Versioned labeled fixture, independent runtime/quality receipts, regression-visible JSON | Fixtures contain no private files; provider identity and preprocessing are explicit; no speed-only promotion | One local command, schema/version/commit/provider IDs, screenshot/duplicate/semantic/review metrics, comparable provider output |
| #28 | Decoder-friendly complete snapshots | No upstream filesystem API is adopted; FileID media/runtime code is only a bounded-work reference | BUILD OURSELVES | Single-open `O_NOFOLLOW` broker stream, explicit size/page/duration limits, fail-closed oversize policy | Decoders receive broker data/streams, never source authority; identity checks and read-only syscalls remain | >8 MiB valid image, >20 MiB valid PDF, large audio/video probe, symlink/TOCTOU/changed-read tests |
| #29 | Whole-computer onboarding | FileID root/library UX is a study reference only; no filesystem mutation is reused | BUILD OURSELVES | Persisted authorized-root state, exclusion explanations, pause/re-authorize controls | Security-scoped read-only bookmarks only; no Full Disk Access shortcut; removing a root changes visibility, not originals | Multiple-root restart, stale bookmark/re-authorize, exclusions prevent indexing and false missing, external disconnect behavior |
| #30 | Magic dashboard and cluster explorer | FileID [`RestructureView.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Views/RestructureView.swift), [`SankeyFlowView.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Views/Restructure/SankeyFlowView.swift), [`RestructureRecommendationRow.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Views/Restructure/RestructureRecommendationRow.swift) | STUDY / BUILD OURSELVES | Aggregated cluster presentation, drill-down, representative/reason display, confidence-aware actions | Adapt presentation to virtual catalog navigation; omit restructure-apply, move, rename, delete, Finder tags, and WebView/server paths | Major groups reachable in ≤2 interactions, cluster member/representative/relation reason, 10k UI smoke, responsive review action |
| #31 | FileID ViT-B/32 vs genuine MobileCLIP vs Python | FileID [`MobileCLIPService.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/engine/Sources/FileIDEngine/Models/MobileCLIPService.swift), [`CLIPTextEncoder.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/app/Sources/FileID/Services/CLIPTextEncoder.swift); genuine reference [`swift-mobileclip/Sources/MobileCLIP/S0Model.swift`](https://github.com/sfomuseum/swift-mobileclip/blob/main/Sources/MobileCLIP/S0Model.swift), [`CLIPTokenizer.swift`](https://github.com/sfomuseum/swift-mobileclip/blob/main/Sources/MobileCLIP/Tokenizer/CLIPTokenizer.swift) | ADAPT / BUILD OURSELVES | Warm model reuse, preprocessing/tokenization, dimension guards, bounded concurrency, pinned artifact provenance | Providers receive bytes/text only; exact embedding space is persisted; FileID ONNX and restructure-apply behavior are not imported | Same Golden fixture; model size, cold/warm image+text, throughput/RSS/install, Recall@K/image retrieval; WINNER/FALLBACK/REJECT before defaulting |
| #32 | Local ASR and media intelligence | FileID media sampling is a reference only; no source-path model API is reused | BUILD OURSELVES | Broker-fed decode, timestamped chunks, speech gate, sparse representative frames | ASR sees PCM only; ffmpeg/whisper are opt-in local adapters and source files remain read-only | Non-empty PCM fixture, real local ASR or explicit unavailable preflight, transcript FTS, unchanged skip, long-media bounded memory |
| #33 | FSEvents live indexing | Apple FSEvents API documentation; no FileID write watcher behavior | BUILD OURSELVES | `UseCFTypes` callback representation, coalescing, dropped-event reconciliation, root lifecycle | Watcher observes authorized roots only; catalog/model/cache/temp exclusions always win; no write entitlement | Real create/modify/delete callback, exclusion-under-root test, storm bound, dropped-event full rescan |
| #34 | Evidence-bound learning semantics | FileID [`RestructureFeedback.swift`](https://github.com/WebWorldWide/FileID/blob/main/platforms/apple/engine/Sources/FileIDEngine/Pipeline/RestructureFeedback.swift) | ADAPT CONCEPT / BUILD OURSELVES | Inspectable correction provenance, confidence feedback, reversible promotion gate | Same normalized pattern + category + positive action + current generation required; rules disabled by default; no self-modification | Unrelated evidence no promotion, removals block additive rules, matching positives promote, mixed evidence deterministic |

## Provider identity note

FileID's Apple `MobileCLIPService.swift` is a ViT-B/32 OpenCLIP-style image
encoder backed by ONNX Runtime/Core ML acceleration, not genuine Apple
MobileCLIP. The genuine MobileCLIP reference has S0/S1/S2/BLT model wrappers,
CLIP BPE resources, and a BSD license. Private Librarian therefore treats
these as separate candidates and records the exact checkpoint, preprocessing,
tokenizer, dimension, and runtime receipt rather than selecting by name.

## External control-board handoff

This file is the local, reviewable artifact for #38. Posting it to the #18
control board is a separate GitHub comment action and remains pending explicit
authorization; no comment, push, merge, or workflow action is performed here.

## Current provider status

`python-transformers` remains the comparison fallback when its local runtime is
actually provisioned. Genuine Core ML MobileCLIP is implemented and has been
validated with a temporary pinned compiled S0 pair: `provider-smoke` produced
real 512-D image/text vectors, warm latency, and a matching-space cosine
receipt. It remains opt-in because that smoke test does not measure Golden
Library Recall@K. FileID's OpenCLIP/ONNX path is deferred as a default until
this checkout has a matching text encoder, ONNX Runtime bridge, and
artifact-backed quality measurement.

The tokenizer adaptation is attributed to the BSD-licensed
`sfomuseum/swift-mobileclip` project; its required notice is retained in
`ThirdParty/SWIFT_MOBILECLIP_LICENSE.md`.
