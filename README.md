# Private Local Librarian

Native macOS local-only librarian that can understand and virtually organize
Desktop/Documents/Downloads-style content while being **technically incapable of
modifying the originals**. Organization lives in a separate encrypted catalog.

> Original files are readable, never writable. The AI layer never receives
> filesystem-writing capabilities.

## Status: Stage A/B/C core, honestly reported

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
| Incremental re-index of changed files | ✅ fixed via path-stable ids (see below) |
| **Exact duplicate detection** | ✅ **FIXED** — size-bucket → partial fingerprint → full SHA-256; report-only. The earlier breakage came from unparameterized catalog queries returning wrong rows; fixed in the same pass. |
| Missing-file sweep | ✅ marks vanished files `missing` on re-scan; one path dialect end-to-end (see ARCHITECTURE.md). |
| SwiftUI app shell | builds; folder picker + bookmark flow unexercised in UI tests |
| OCR / embeddings / speech / video sampling | not started (Stage D/E) |
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
swift test                       # mandatory security suite (19 tests)
scripts/gen_fixtures.py /tmp/fl  # synthetic fixture tree (never your real Desktop)
scripts/audit_entitlements.py dist/PrivateLibrarian.app
scripts/network_negative_probe.py
```

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
