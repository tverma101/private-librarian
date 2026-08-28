# Architecture

Private Local Librarian is a native macOS app + core library that builds a
searchable, virtually organized catalog of a user's local folders while being
**technically incapable of modifying the originals**.

> Original files are readable, never writable. The AI layer never receives
> filesystem-writing capabilities. Organization exists only inside an
> encrypted catalog.

## Invariant stack (each layer independently enforces the last)

```
macOS App Sandbox + read-only, user-selected security-scoped access
        +
deterministic SourceBroker (O_RDONLY|O_NOFOLLOW only; no write syscalls
anywhere in the source subsystem; symlink + TOCTOU refusal)
        +
deterministic rule-based classification behind a strict output-schema wall
(the ClassifierContract discards any output that fails validation — the
same gate a future LLM classifier would face; prompt injection inside
document text cannot cross it because there is no tool to call)
        +
SQLCipher-encrypted catalog on disk (key generated once, held in the
macOS Keychain, never written next to the db) with FTS5 full-text search
        +
virtual organization only — categories are rows in `virtual_categories`,
never directories; nothing is ever moved, renamed, deleted, re-tagged,
or permission-changed at the source
```

## Module map

| Module | Responsibility |
|---|---|
| `SourceBroker` | The ONLY component that touches source paths. Opens files read-only with component-safe `openat` + `O_NOFOLLOW` traversal, re-stats the opened fd, refuses symlinks and non-regular files, and exposes bounded evidence reads plus complete fail-closed decoder snapshots (`completeSnapshot` / `streamCompleteSnapshot`). Enumeration walks breadth-first with per-directory sort, records symlinks as metadata and **never descends into them**, skips packages/bundles. Reported paths are built by joining names onto the caller's root spelling — see "One path dialect" below. |
| `SafeReader` semantics | Every read goes through the broker's no-follow fd; a file swapped for a symlink between stat and open fails with ELOOP instead of leaking content. |
| `FileIdentity` / `FileID` | lstat-level identity (size, mtime, ctime, fs file id). Catalog ids are SHA-256 of the path only — stable across edits so child rows (text, classifications, hashes) survive re-indexing. |
| `EvidenceExtractor` | Bounded evidence: UTF-8 sample, magic-byte sniffing, cloud-placeholder detection (never hydrates). |
| `PDFText` / `OfficeContainer` | Content extraction through broker-owned bytes; PDF/container decoders receive a complete snapshot within an explicit cap, or no input. Malformed input yields empty evidence, never a crash. |
| `ScreenshotIntelligence` | Broker-byte image metadata/dimensions plus weak filename, OCR, and optional Vision labels form explainable Tier-1 screenshot evidence. It emits subtype, confidence, and reason codes; uncertain results also join `Review`. No filename-only detection and no provider-specific semantic model. |
| `VisionOCR` | On-device Vision text recognition from broker-supplied image bytes; scanned PDFs are rendered from a complete broker snapshot and only rendered page images are capped. |
| `BrokerPCMDecoder` / `WhisperCLITranscriptionProvider` | Optional local-only media path: complete broker snapshot → PCM decode → bounded timestamped chunks → preflighted local ASR. Uncompressed RIFF/WAVE-PCM is demuxed internally (pure Foundation — deterministic on hosts without ffmpeg, including CI); compressed containers fall back to the ffmpeg stdin path and fail closed when it is absent. No indexed source path is passed to the decoder or model. |
| `RuleBasedClassifier` + `ClassifierContract` | Deterministic classifier; screenshot results add virtual `Screenshots/<subtype>` memberships and retain the strict output contract. |
| `LearnedRuleEngine` | Applies only enabled, evidence-bound correction rules after contract validation; promotion requires three distinct matching additive corrections, remains disabled by default, and negative corrections block promotion. |
| `Scheduler` | Serializes work into LOW/MEDIUM/HIGH slots so indexing never starves interactive work; also the seam where an LLM stage would be rate-limited later. |
| `Catalog` | All SQLCipher/FTS5 access: files, virtual categories, memberships, screenshot assessments, hashes, errors, correction-bound learned rules, similarity clusters, and per-root onboarding coverage. Key from `CatalogKeychain` (Keychain generic-password item, `AfterFirstUnlockThisDeviceOnly`). |
| `EmbeddingProvider` | Provider-neutral image/text contract. Python and Core ML artifacts are admitted only with pinned provenance manifests; `CoreMLMobileCLIPProvider` loads the genuine MobileCLIP S0 image/text pair lazily, validates 512-D output, and accepts broker bytes only. An explicitly requested unavailable provider stays unavailable instead of silently switching model spaces. |
| `MobileCLIPTokenizer` | Local CLIP BPE tokenizer for the Core ML text input (`[1,77]` Int32); it reads only the provisioned vocab/merges assets and never receives a source path. |
| `OrganizationGraphBuilder` | Deterministic multi-label file/category/review/missing relationships persisted as encrypted catalog edges. Graph output is virtual and never performs source filesystem operations. |
| `ReviewInbox` | Low-confidence queue plus catalog-only correction actions. Corrections persist category overrides so a later re-index cannot silently undo a user's choice. |
| `Indexer` | Pipeline: enumerate → identity → extract → classify → commit, with identity re-stat immediately before commit ("changed-during-index" discard). End-of-run missing-sweep marks vanished files `missing` — never deletes anything anywhere. |
| `DuplicateDetector` | Size-bucket → partial fingerprint (head/middle/tail 64 KiB) → full SHA-256 within matching partial groups. Report-only verdicts. |
| `scripts/benchmark_quality.py` | Model/provider-neutral Golden Library metrics: screenshot subtype accuracy/macro-F1, exact/near-duplicate precision/recall/F1, semantic Recall@10, cluster purity/completeness, OCR recovery, review precision/coverage, correction reduction, and explicit model/preprocessing/runtime comparison records. |
| `SimilarityClustering` | Provider-neutral exact-hash, feature-print, and embedding adapters feed explicit near-duplicate/semantic threshold edges. Stable family/cluster IDs, representatives, weakest-link confidence, and signal reasons are persisted in SQLCipher; incremental updates rescore only changed neighborhoods and remove missing-node edges. |
| `SearchService` | FTS5 query front-end plus optional provider-backed MiniLM/CLIP and Vision search; semantic/vector paths join only indexed catalog rows, collapse chunk hits, apply virtual/date/duplicate filters, and quote-escape FTS input. |
| `LiveIndexCoordinator` | Optional read-only FSEvents reconciliation for authorized roots. Streams use `kFSEventStreamCreateFlagUseCFTypes` and decode bounded CFArray path delivery; catalog, model, cache, and temporary paths remain excluded even beneath watched roots. Dropped events trigger the existing bounded full-rescan fallback. |
| `librarian-cli` | Read-only verification harness: `index` / `search` / `status` / `dupes` / `tree` / `graph-stats` / `provider-smoke`; it reports work, similarity, embedding, and graph metrics without exposing source writes. |
| `LibrarianApp` | SwiftUI dashboard with persisted read-only security-scoped root onboarding, per-root pause/remove/reauthorize, exclusions, overview, screenshot/missing explorers, review inbox, graph view, and privacy status; sandboxed `.app` packaging via `scripts/package_app.sh` or `script/build_and_run.sh`. |

Decoder boundary: compressed PDF/image containers must use the broker's
complete snapshot/stream API. The normal 8 MiB evidence cap is not a decoder
cap: a valid container above it is read whole when within policy, otherwise it
is rejected before decoding. Downstream Vision/search/model helpers receive
bytes only and never source paths. The media decoder adopts this same API.

## One path dialect (enumeration contract)

`SourceBroker.enumerate(root:)` reports every discovered path as
`<root.path>/<component>/…`, built from its own walk — **not** the canonicalized
child URLs `FileManager.contentsOfDirectory(at:)` returns (on macOS those come
back as `/private/var/...` even when you passed `/var/...`). Emitting raw child
URLs put two spellings of one tree into a single run and silently broke the
missing-file sweep's set comparisons. Contract now: enumerate output, catalog
rows, and the sweep's seen-set/prefix all share the caller's spelling by
construction. Disk operations inside enumerate keep using the real URLs.

## Missing-file semantics

When a previously indexed file under the scanned root is absent at the next
scan, its row is marked `status='missing'`. Nothing is ever reconstructed,
re-downloaded, or deleted twice; the record exists so search results can be
annotated honestly. Rows outside the current root prefix are never touched.

## Similarity semantics

Similarity is derivative catalog state, never a source-file operation. Exact
hash and feature-print adapters produce `nearDuplicate` relations; embedding
adapters produce `semantic` relations. Adapters own their providers and score
spaces, while the graph engine only applies deterministic thresholds and
connected components. Cluster and family IDs hash the sorted member IDs and
relation, and representative selection uses weighted graph degree followed by
optional confidence and lexical tie-breaks. A changed or added node causes
only its incident neighborhood to be regenerated; a missing node loses its
edges and catalog membership but is not deleted from the catalog.
When both signals connect the same files, near-duplicate and semantic
components remain separate clusters rather than being relabeled by whichever
relation has more edges.
Rows intentionally excluded by onboarding are skipped during enumeration and
are not treated as vanished during the missing-file sweep. Removing an
exclusion makes the same catalog row eligible for normal incremental
reconciliation again.

## Fixture honesty

The symlink-breakout fixture places `Forbidden/` **outside** the scanned root
(sibling of `TestLibrary`) with `Symlinks/escape -> ../Forbidden` inside it.
This makes the invariant directly observable: any appearance of
`Forbidden/secret.txt` in the catalog means real containment failure, not a
legitimate in-scope copy. Both the Swift test fixture and `gen_fixtures.py`
follow this shape.
