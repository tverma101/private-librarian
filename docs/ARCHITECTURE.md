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
| `SourceBroker` | The ONLY component that touches source paths. Opens files `O_RDONLY\|O_NOFOLLOW`, refuses symlinks and non-regular files, bounded evidence reads plus complete fail-closed snapshots (`completeSnapshot` / `streamCompleteSnapshot`) for container decoders. Enumeration walks breadth-first with per-directory sort, records symlinks as metadata and **never descends into them**, skips packages/bundles. Reported paths are built by joining names onto the caller's root spelling — see "One path dialect" below. |
| `SafeReader` semantics | Every read goes through the broker's no-follow fd; a file swapped for a symlink between stat and open fails with ELOOP instead of leaking content. |
| `FileIdentity` / `FileID` | lstat-level identity (size, mtime, ctime, fs file id). Catalog ids are SHA-256 of the path only — stable across edits so child rows (text, classifications, hashes) survive re-indexing. |
| `EvidenceExtractor` | Bounded evidence: UTF-8 sample, magic-byte sniffing, cloud-placeholder detection (never hydrates). |
| `PDFText` / `OfficeContainer` | Content extraction through broker-owned bytes; PDFs use a complete snapshot with a fail-closed cap, malformed input yields empty evidence, never a crash. |
| `VisionOCR` | On-device Vision text recognition from broker-supplied image bytes; scanned PDFs are rendered from a complete broker snapshot and only rendered page images are capped. |
| `RuleBasedClassifier` + `ClassifierContract` | Deterministic v1 classifier; its JSON output must pass schema validation or the result is discarded wholesale (contract wall). |
| `Scheduler` | Serializes work into LOW/MEDIUM/HIGH slots so indexing never starves interactive work; also the seam where an LLM stage would be rate-limited later. |
| `Catalog` | All SQLCipher/FTS5 access: files, virtual categories, memberships, hashes, errors. Key from `CatalogKeychain` (Keychain generic-password item, `AfterFirstUnlockThisDeviceOnly`). |
| `Indexer` | Pipeline: enumerate → identity → extract → classify → commit, with identity re-stat immediately before commit ("changed-during-index" discard). End-of-run missing-sweep marks vanished files `missing` — never deletes anything anywhere. |
| `DuplicateDetector` | Size-bucket → partial fingerprint (head/middle/tail 64 KiB) → full SHA-256 within matching partial groups. Report-only verdicts. |
| `SearchService` | FTS5 query front-end with quote-escaping so user input can't break out of query syntax. |
| `librarian-cli` | Read-only verification harness: `index` / `search` / `status` / `dupes` / `tree`. |
| `LibrarianApp` | SwiftUI shell; sandboxed `.app` packaging via `scripts/package_app.sh`. |

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

## Fixture honesty

The symlink-breakout fixture places `Forbidden/` **outside** the scanned root
(sibling of `TestLibrary`) with `Symlinks/escape -> ../Forbidden` inside it.
This makes the invariant directly observable: any appearance of
`Forbidden/secret.txt` in the catalog means real containment failure, not a
legitimate in-scope copy. Both the Swift test fixture and `gen_fixtures.py`
follow this shape.
