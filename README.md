# Private Local Librarian

Native macOS local-only librarian that can understand and virtually organize
Desktop/Documents/Downloads-style content while being **technically incapable of
modifying the originals**. Organization lives in a separate encrypted catalog.

> Original files are readable, never writable. The AI layer never receives
> filesystem-writing capabilities.

## Status: integrated local backlog, honestly reported

| Component | State |
|---|---|
| SourceBroker (O_RDONLY\|O_NOFOLLOW only) | ✅ implemented, symlink-refusal + TOCTOU tests pass |
| SQLCipher catalog (vendored 4.17.0, CommonCrypto provider) | ✅ compiled into binary; encryption/wrong-key/no-plaintext tests pass |
| FTS5 search inside encrypted catalog | ✅ test passes |
| Prompt-injection containment (contract wall) | ✅ tests pass — hostile classifier output is discarded |
| Parser-crash resilience (malformed PDF/JPEG/ZIP) | ✅ tests pass — indexing survives |
| Catalog-loss rebuild / original-loss → `missing` | ✅ tests pass |
| Immutability zero-diff (§37) | ✅ tests pass |
| Virtual categories (multi-label, hierarchical) | ✅ tests pass; no real dirs ever created |
| Organization graph (multi-label virtual relationships) | ✅ encrypted catalog edges + deterministic graph snapshot; no source mutation |
| Review Inbox + one-click correction | ✅ low-confidence queue, persistent catalog-only overrides, reversible membership correction |
| Learning loop | ✅ evidence-bound deterministic rules; three matching additive corrections promote a disabled-by-default rule, while negative corrections block promotion |
| Whole-computer onboarding | ✅ persisted read-only security-scoped roots, per-root pause/remove/reauthorize, exclusions, aggregate and per-root coverage counters |
| Magic dashboard / explorers | ✅ native SwiftUI overview, review, graph, screenshot, school, projects, documents, media, duplicate, and missing explorer surfaces |
| Incremental re-index of changed files | ✅ fixed via path-stable ids (see below) |
| **Exact duplicate detection** | ✅ **FIXED** — size-bucket → partial fingerprint → full SHA-256; report-only. The earlier breakage came from unparameterized catalog queries returning wrong rows; fixed in the same pass. |
| Screenshot intelligence | ✅ Tier-1 metadata/dimension/filename/content evidence; OCR and optional Vision labels use broker bytes; subtype/confidence/reasons persist encrypted; virtual `Screenshots/*` plus `Review` routing. |
| **Similarity families** | ✅ deterministic encrypted threshold graph with explicit near-duplicate vs semantic relations, provider-neutral hash/feature/embedding adapters, stable IDs/representatives, persisted confidence/reason, and incremental add/change/missing neighborhood updates |
| Missing-file sweep | ✅ marks vanished files `missing` on re-scan; one path dialect end-to-end (see ARCHITECTURE.md). |
| 10k-library benchmark | ✅ cold/warm/one-file-change/duplicate/FTS receipts recorded locally; 100k remains opt-in and unclaimed |
| Complete decoder snapshots | ✅ broker-owned whole-container API with explicit fail-closed cap; PDF/image/model consumers receive bytes, never source paths. |
| SwiftUI app shell | ✅ release build and startup verified; folder picker + bookmark flow remain human/UI-bound |
| Media probe + broker-safe PCM decode + transcript FTS | ✅ E2E-tested on generated WAV (decode → provider → transcript → encrypted catalog → FTS) with no external binaries required; unchanged re-index provably does zero decode/ASR; a changed generation replaces or purges transcripts atomically. Provisioned local Whisper integration is host-conditional; ASR remains opt-in and fail-closed |
| OCR / embeddings / speech inference / video sampling | partial: broker-byte OCR, optional local embeddings, local ASR, and sparse video sampling are wired; provider quality/runtime coverage remains host- and model-conditional, with ASR and embeddings opt-in |
| OCR | ✅ broker-byte Vision OCR + scanned-PDF fallback; complete-container snapshot policy; no source writes |
| Golden Library quality harness | ✅ synthetic-golden-v1 screenshot macro-F1 + non-screenshot controls, exact/near-duplicate precision/recall/F1, semantic Recall@10, cluster purity/completeness, OCR/review/correction metrics, and provider/runtime identity comparison |
| Vision image analysis + optional local embeddings | ✅ on-device Vision always works; Python/Core ML Tier-2 preflight requires pinned provenance manifests and fails closed |
| Genuine MobileCLIP Core ML | ✅ real bytes-only runtime + tokenizer + artifact smoke command; optional model pair is not provisioned here |
| Sandboxed .app entitlement audit in CI | script exists (`scripts/audit_entitlements.py`); wired into GitHub Actions |

## Bugs found and fixed during verification

1. **Silent unencrypted fallback**: the "SQLCipher" target originally shipped
   only a shim, so every binary linked the system `libsqlite3.dylib` (no
   codec). Caught because tests demanded real encryption. The amalgamation is
   now compiled directly into the target (`otool -L` shows no system sqlite;
   `nm` shows sqlcipher symbols).
2. **Identity instability on re-index**: file ids were derived from
   size+mtime, so any modified file got a new id while child rows still
   pointed at the old one → `FOREIGN KEY constraint failed` and stale rows.
   Ids are now derived from the path hash only; size/mtime update in place.
3. **Two path spellings in one index run**: `FileManager.contentsOfDirectory`
   canonicalizes `/var/...` to `/private/var/...`, so enumerate output,
   catalog rows, and the missing-file sweep compared different dialects —
   vanished files were never marked `missing`. Enumeration now emits paths
   joined onto the caller's root spelling by construction (docs/ARCHITECTURE.md).
4. **Unwinnable symlink test / fixture dishonesty**: the fixture placed
   `Forbidden/secret.txt` inside the scanned root, so "never indexed" could
   never be asserted meaningfully. Fixture moved outside the root (Swift +
   gen_fixtures.py); the invariant is now directly observable.
5. **Unparameterized catalog helpers** (`fingerprint/fileRow/confidence/
   fileKind`) ignored their argument and returned arbitrary rows — this was
   what broke duplicate detection downstream. All take bound parameters now.

## Build & verify

```bash
swift build                      # all targets
swift test                       # mandatory security suite (116 tests)
swift build -c release           # production CLI + app build
bash scripts/e2e_local.sh        # release-binary safety and encryption E2E
scripts/package_app.sh .build/release
scripts/gen_fixtures.py /tmp/fl  # synthetic fixture tree (never your real Desktop)
scripts/audit_entitlements.py dist/PrivateLibrarian.app
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
python3 scripts/bench_providers.py --providers local fileid coreml
.build/release/librarian-cli provider-smoke --samples 5
```

Compressed PDF/image containers use `SourceBroker.completeSnapshot` (or its
streaming form), not the 8 MiB bounded evidence read. Valid containers above
that evidence cap are passed whole within `maxSnapshotBytes`; oversized
containers are rejected before decoding. The media decoder uses the same API.
OCR container reads use the broker's complete-snapshot API with an explicit
fail-closed size ceiling. Images passed to OCR may be capped for Vision's
per-image policy, but compressed PDF/image containers are never silently
parsed from a truncated prefix.

The Core ML MobileCLIP path is opt-in. Provisioning and compilation are
separate, explicit steps:

```bash
python3 scripts/provision_mobileclip_coreml.py --download
scripts/compile_mobileclip_coreml.sh
```

The Python baseline uses the same pattern:

```bash
python3 scripts/provision_image_models.py --all
python3 scripts/provision_image_models.py --all --verify-only
```

Both embedding paths require pinned provenance manifests before activation.
The application never downloads models or passes a source path to an embedding
provider; image bytes and derived text cross the helper boundary over stdin.
See [the upstream reuse audit](docs/UPSTREAM_REUSE.md) for the FileID and
genuine MobileCLIP decisions.

The dashboard's graph, review corrections, exclusions, and coverage state are
catalog records. They do not create directories or write to an authorized
source root. Feature-specific OCR, media, provider, screenshot, similarity,
and benchmark lanes are integrated below the same source-safety boundary.

## Architecture

See docs/ARCHITECTURE.md and the original hardened plan embedded in git
history. Core invariant stack:

```
macOS App Sandbox + read-only security-scoped bookmarks
        +
deterministic SourceBroker (no ML, no write syscalls in source subsystem)
        +
tool-less local classification behind a strict output-schema wall
        +
SQLCipher-encrypted catalog (key in Keychain) with FTS5
        +
virtual organization only — never real moves/renames/deletes
```
