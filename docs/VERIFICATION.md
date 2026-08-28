# Verification

This page describes how to verify the current repository and how to interpret the measurements recorded here.

## Source of truth

For a current commit, GitHub Actions and a fresh local run are the source of truth. Historical benchmark numbers below are useful for comparison, but they are not release guarantees.

The integrated branch has three CI jobs:

- `test` — build, full Swift test suite, Tier-2 provider contract, and vendored SQLCipher provenance checks;
- `quality` — deterministic Golden Library metric/schema checks;
- `entitlement-audit` — release build, local E2E verification, packaged-app entitlement audit, and network-negative probe.

CI also rejects public-repository hygiene mistakes such as tracked credential/signing files, downloaded model folders, and real-looking personal `/Users/...` paths in source/tests/docs.

## Reproduce the normal checks

From the repository root:

```bash
swift build
swift test
```

For the release-style verification path:

```bash
swift build -c release
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```

For the deterministic quality harness:

```bash
python3 -B scripts/benchmark_quality.py --output quality-result.json
```

For the synthetic performance harness:

```bash
python3 scripts/benchmark_librarian.py --files 10000 --search-iters 5 --relation-iters 3
```

## What the Swift suite covers

The test suite includes coverage for:

- source immutability across indexing passes;
- symlink refusal, intermediate-symlink breakout, and path-swap/TOCTOU handling;
- catalog encryption and wrong-key refusal;
- malformed-file resilience;
- prompt-injection data remaining inert;
- exact duplicate detection without deletion;
- missing-file handling;
- incremental zero-work behavior for unchanged files;
- OCR and complete compressed-container snapshots;
- screenshot classification and persisted evidence;
- similarity families and incremental neighborhood updates;
- live FSEvents coalescing, exclusions, and dropped-event reconciliation;
- Review Inbox corrections and evidence-backed learned rules;
- media decoding, transcript persistence/search, and stale-transcript handling;
- provider/indexer/catalog/search integration;
- organization graph and onboarding coverage.

The real provisioned Whisper test is host-conditional. Hosted CI does not ship a local Whisper executable/model, so that test is expected to skip there while the generated-fixture media pipeline remains exercised without an external model.

## Known compiler warning

The current integrated app still emits Swift concurrency diagnostics around the background indexing callback flow. The build succeeds under the current toolchain, but those diagnostics are tracked in issue #46 because they become errors under Swift 6 language-mode enforcement.

Do not describe the current build as warning-free until #46 is closed and a fresh CI run confirms it.

## Packaging and sandbox checks

`scripts/package_app.sh` builds the release-style `.app` and signs it with the configured identity (ad-hoc by default for local verification).

The entitlement audit expects:

- App Sandbox enabled;
- user-selected read-only file access;
- app-scoped bookmarks;
- no source read-write entitlement;
- no network client/server entitlement.

The network-negative probe runs inside an additional deny-network sandbox and attempts outbound and local network operations. Those attempts must be denied.

The CLI is a development/verification tool and must not be copied into the production app bundle.

## SQLCipher provenance

SQLCipher is vendored under `ThirdParty/sqlcipher/` with its license and provenance files. CI checks the expected vendored source/provenance rather than allowing an accidental system SQLite fallback to go unnoticed.

Catalog tests also verify encrypted-on-disk behavior and wrong-key failure.

## Optional embedding providers

The default app does not require downloaded model artifacts.

Provider checks are explicit and fail closed. A requested provider should be reported unavailable when its expected artifacts, tokenizer data, dependencies, or provenance are incomplete rather than silently switching model spaces.

Useful commands include:

```bash
python3 scripts/bench_providers.py --providers local fileid coreml --output provider-results.json
.build/release/librarian-cli provider-smoke --samples 5
```

A successful Core ML MobileCLIP smoke run proves that the native provider can produce matching-space image/text vectors from broker-supplied bytes/text. It does not by itself prove that the provider wins the Golden Library retrieval-quality comparison.

## Historical 10k synthetic snapshot

A local 10,000-file synthetic run recorded on August 25, 2026 produced approximately:

| Measurement | Historical result |
|---|---:|
| Cold index | 72.183 s |
| Cold throughput | 138.6 files/s |
| Warm unchanged index | 1.077 s |
| One-file change | 1.127 s |
| Duplicate pass | 0.533 s |
| FTS search p50 | 117.52 ms |
| FTS search p95 | 119.54 ms |
| Graph query p50 | 242.56 ms |
| Graph query p95 | 244.62 ms |
| Peak RSS reported by harness | 25.5 MB |
| Catalog size | 18,243,584 bytes |

Treat these as a historical development snapshot, not an SLA or a current-commit benchmark. Re-run the harness when comparing performance-sensitive changes.

A 100,000-file run was started during development but did not complete, so the project makes no 100k performance claim.

## Current gaps that affect verification

Several important app-level behaviors remain open and should not be inferred from lower-level green tests:

- #42 — ASR provider/model identity must participate in incremental invalidation;
- #43 — transcription failure needs explicit retry semantics;
- #44 — live indexing needs a persistent security-scoped permission lifetime in the sandboxed app;
- #45 — missing/stale saved bookmarks must fail closed rather than falling back to raw-path access;
- #46 — Swift 6 concurrency warnings need cleanup;
- #47 — the implemented local transcription backend still needs app-level settings/wiring.

A green CI run means the checked behaviors passed. It does not mean those open product gaps are already solved.
