# Security Model

## The one-sentence model

Original files are readable, never writable: every component that can name a
source path is restricted to open-once-`O_RDONLY|O_NOFOLLOW` semantics, and
all "organization" is rows in an encrypted catalog — the system contains no
code path that renames, moves, deletes, re-tags, permission-changes, or
rewrites a source file.

## Threats and controls

| Threat | Control | Verified by |
|---|---|---|
| Buggy model / malicious document tells the AI to delete or exfiltrate | No filesystem-writing capability exists in the source subsystem; classifier output must pass the schema contract wall or be discarded | PromptInjectionTests, ImmutabilityAndSymlinkTests |
| Symlink breakout to files outside the scanned root | Enumeration lstat-checks every child, records links as metadata, never descends; direct reads reject symlinked path components and walk canonical directories with `openat` + `O_NOFOLLOW` (ELOOP on TOCTOU swap) | SymlinkEscapeTests (`Forbidden/` lives OUTSIDE the fixture root) |
| Malformed file crashes the indexer (parser bombs) | Extraction is bounded and error-isolated per file; failures become opaque `errors` rows, indexing continues | ResilienceTests (truncated PDF, fake JPEG, corrupt ZIP) |
| Catalog theft | SQLCipher 4.17.0 compiled into the binary (no system libsqlite3 fallback), key = 32 random bytes in the Keychain, never on disk next to the db | encryption tests + `status` header check |
| Wrong key opens old catalog | SQLCipher refuses; tests assert failure, not silent plaintext | ResilienceTests |
| Silent downgrade to unencrypted sqlite | `Catalog.onDiskHeaderIsPlaintextSQLite` checks the on-disk header; CLI prints `encrypted-on-disk=` every run | E2E receipts |
| Duplicate detector deleting "copies" | Detector is report-only by construction — it has no delete API | BehaviorTests assert both copies still exist |
| Deleted originals ghosting in search results | Missing-sweep marks rows `missing`; nothing is reconstructed or deleted twice | ResilienceTests.testOriginalLossIsRecordedNotRepaired |
| Truncated media container reaching a decoder | Complete snapshots reject oversize sources instead of decoding a prefix; decoder receives broker stdin only | MediaIntelligenceTests.testBrokerCompleteSnapshotIsNotTruncatedAndFailsClosed |
| ASR accidentally running without a local model | Whisper backend preflight requires an executable and readable model; Indexer ASR is opt-in | MediaIntelligenceTests.testWhisperBackendPreflightReportsMissingLocalModel |
| Review correction accidentally changing originals | Corrections are catalog memberships plus persistent overrides; no source path is opened for writing | RoadmapCompletionTests.testReviewInboxAndOneClickCorrectionAreCatalogOnly |
| Excluded onboarding roots being indexed or marked missing | SourceBroker skips excluded prefixes and Indexer ignores them during missing reconciliation | RoadmapCompletionTests.testExcludedRootsAreSkippedWithoutMarkingExistingRowsMissing |
| Over-broad entitlements in packaged app | App Sandbox ON, `user-selected.read-only`, bookmarks app-scope; auditor fails on any write/network/audio/photos entitlement | scripts/audit_entitlements.py in CI |
| Network exfiltration from the app | No network entitlements; network-negative probe expects outbound DNS/TCP/HTTP, LAN, localhost, and listen attempts all DENIED | scripts/network_negative_probe.py |
| Image inference leaks to cloud | All AI image sorting runs 100% on-device: Apple Vision (`VNClassifyImageRequest`/`VNGenerateImageFeaturePrintRequest`) + optional local models from `Models/`; no network entitlement, no download in CI, no telemetry | VisionImageAnalyzer + LocalModelBridge + scripts/embed.py |
| Local embedding helper phones home | `scripts/embed.py` runs with `local_files_only=True` on checkpoints under `Models/`; Swift side is pinned python + `HF_HUB_OFFLINE=1`, timeout-bounded, piped stdin (argv-safe), no shell; indexed path is never passed to the helper as a path | Network-negative probe + LocalModelBridge stdin path |
| Raw file path leaks in helper argv | Image bytes and query text cross the process boundary on stdin; the helper never receives a filesystem path or text payload in argv | LocalModelBridge.embedImageBytes / embedText |
| Pipe-buffer deadlock from large embedding JSON | Helper stdout/stderr are drained after the wait rather than read eagerly so a 512-float vector never wedges a fixed pipe buffer | LocalModelBridge.runPython |
| Long docs lose recall past a single embedding window | Documents are chunked (900-char window, 120 overlap) into `embedding_chunks` alongside the whole-document row; search keeps the max chunk score per file | embedding_chunks + SearchService.semanticSearch |
| Stale embedding space after a model family change | `processingVersion` carries `Index.embeddingSpaceVersion` when Tier 2 is enabled so a MiniLM→CLIP-text switch forces a one-time re-index | ChangeDetection.needsProcessing |
| Stale transcript presented as current after a source changes | `processingVersion` carries the ASR opt-in state, so enabling/disabling ASR forces one honest re-index; a regenerated transcript replaces the old rows inside the same commit transaction, and a generation whose decode now fails purges the previous transcript in that same transaction — old speech is never served as current | Indexer media lane + ChangeDetection.needsProcessing |
| Decoder/model gaining source filesystem authority | The media lane passes only broker streams: `completeSnapshot`/`streamCompleteSnapshot` bytes go to the internal RIFF demuxer or ffmpeg stdin; ASR receives PCM chunks and writes its own temp WAV. Original paths are never handed to a decoder subprocess argv or a model provider | SourceBroker + BrokerPCMDecoder + SpeechTranscriptionProvider |
| Native model path downloads or reads originals directly | MobileCLIP provisioning is a separate opt-in script; runtime accepts only broker-supplied image bytes, reads model artifacts outside authorized source roots, and fails closed when the compiled image/text pair, tokenizer, or pinned provenance manifest is incomplete | CoreMLMobileCLIPProvider + provider-smoke |

## AI image sorting — privacy note

`VisionImageAnalyzer` uses the **on-device** Vision framework. The model lives in
`/System/Library/Frameworks/Vision.framework`, runs on ANE/GPU via
`VNImageRequestHandler(data:)`, never leaves the process, never hits the
network. The app has **no** `network.client`/`network.server` entitlement —
on-device Vision works without one. Downloaded models (`Models/clip-vit-base-patch32` + `Models/all-MiniLM-L6-v2`, gitignored, provisioned via
`scripts/provision_image_models.py --all`) also run locally and offline via `scripts/embed.py` (`local_files_only=True`, `sentence_transformers` / `transformers` on CPU) bridged by `LocalModelBridge` (timeout-bounded subprocess, no shell, no network). Both the helper and Swift preflight require the pinned `provenance.json` identity/file manifest; unverified legacy directories are inactive. `Models/` is outside the indexed tree.

Tiering: **Tier 1 Vision** (zero-download, always on) handles image labels + feature-print dedup. **Tier 2 local embeddings** (opt-in, provisioned) add `clip-vit-base-patch32` 512-d image search (higher recall than Vision) and `all-MiniLM-L6-v2` 384-d semantic text search; when not provisioned every call returns `[]` and indexing/search never block.

The genuine MobileCLIP S0 adapter is a separate 512-D joint space. It requires
compiled `mobileclip_s0_image.mlmodelc` and `mobileclip_s0_text.mlmodelc` files
plus the pinned CLIP BPE vocabulary. `EmbeddingProviderPreflight` reports that
exact state and the pinned provenance manifest; runtime re-hashes manifest
files before activation, and artifact presence alone never activates the
provider. An explicitly requested unavailable provider remains unavailable
instead of silently switching model spaces.

## What remains staged or conditional

- OCR / speech / video quality (Stage E) — broker-safe OCR, sparse video
  sampling, and opt-in local ASR are integrated; provider/model availability
  and quality benchmarking remain host-conditional.
- LLM-assisted classification — the seam exists (Scheduler slots +
  ClassifierContract wall) but no LLM runs; tag quality is Vision + rules.
- ANN index — `SearchService` linear-scans the encrypted `embeddings` table; fine for <100k docs, will need `sqlite-vec` or HNSW for larger libraries.
- GUI folder-picker flow — SwiftUI shell builds; bookmark flow unexercised.

Honest gaps are tracked in the README status table.
