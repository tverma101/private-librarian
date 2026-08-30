# Verification

This page describes how to verify the current repository and how to interpret development measurements.

## Source of truth

For a current commit, a fresh GitHub Actions run and a fresh local run are the source of truth. Historical benchmark numbers below are comparison data, not release guarantees.

The normal CI workflow has three jobs:

- `test` — public-repository hygiene, build, full Swift suite, Tier-2 provider contract, and vendored SQLCipher provenance;
- `quality` — deterministic Golden Library metric/schema checks;
- `entitlement-audit` — release build, local E2E verification, packaged-app entitlement audit, and network-negative probe.

## Reproduce the normal checks

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test
```

For the release-style path:

```bash
swift build -c release
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```

Quality/performance harnesses:

```bash
python3 -B scripts/benchmark_quality.py --output quality-result.json
python3 scripts/benchmark_librarian.py --files 10000 --search-iters 5 --relation-iters 3
```

## What the Swift suite covers

The suite includes coverage for:

- source immutability;
- symlink refusal and path-swap/TOCTOU handling;
- catalog encryption and wrong-key refusal;
- malformed-file resilience;
- prompt-injection content remaining inert;
- exact duplicate detection without deletion;
- missing-file handling;
- incremental zero-work behavior;
- OCR and complete compressed-container snapshots;
- screenshot classification and persisted evidence;
- similarity families and incremental neighborhood updates;
- live FSEvents coalescing/exclusions/dropped-event reconciliation;
- Review Inbox corrections and evidence-backed learned rules;
- media decoding, transcript persistence/search, ASR provider invalidation, failure/retry/no-transcript semantics, and stale-transcript suppression;
- provider/indexer/catalog/search integration;
- organization graph and onboarding coverage;
- bounded Smart Groups, raw-label suppression, lane diversity limits, and legacy taxonomy pruning.

The real provisioned Whisper test is host-conditional. Hosted CI does not ship the user's local Whisper executable/model, so that test is expected to skip there while generated-fixture media tests still exercise the production indexing pipeline.

## Concurrency checking

The integration branch is also built with:

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

This is the regression gate for the app-model callback problem previously tracked in #46. Background indexing remains off the main actor while progress/completion handoff is actor-aware.

## Packaging and sandbox checks

`scripts/package_app.sh` builds a release-style `.app` and signs it with the configured identity (ad-hoc by default for local verification).

The entitlement audit expects:

- App Sandbox enabled;
- user-selected read-only file access;
- app-scoped bookmarks;
- no source read-write entitlement;
- no network client/server entitlement.

The network-negative probe runs inside an additional deny-network sandbox and attempts outbound/local network operations. Those attempts must be denied.

The CLI is a development/verification tool and must not be copied into the production app bundle.

## SQLCipher provenance

SQLCipher is vendored under `ThirdParty/sqlcipher/` with license and provenance files. CI checks the expected vendored source/provenance so an accidental system SQLite fallback does not go unnoticed. Catalog tests also verify encrypted-on-disk behavior and wrong-key failure.

## Optional providers

The default app does not require downloaded model artifacts.

Embedding providers fail closed when expected artifacts, tokenizer data, dependencies, or provenance are incomplete rather than silently switching model spaces.

Useful commands include:

```bash
python3 scripts/bench_providers.py --providers local fileid coreml --output provider-results.json
.build/release/librarian-cli provider-smoke --samples 5
```

A successful Core ML MobileCLIP smoke run proves that the provider can produce matching-space image/text vectors from broker-supplied data. It does not by itself prove that provider wins a Golden Library retrieval-quality comparison.

Local Whisper is opt-in. The app only enables it when the configured executable/model passes preflight. The ASR processing identity includes provider/model generation so configuration changes invalidate unchanged media once and then return to normal incremental skips.

## Smart organization verification

The organizer deliberately has a second, bounded presentation layer above raw classifications/similarity data. Regression tests require that:

- raw Vision labels do not create arbitrary taxonomy folders;
- broad stable categories are used instead;
- singleton taxonomy noise is not promoted;
- Smart Groups stay globally bounded;
- duplicate, screenshot, school, project, semantic, and general lanes cannot monopolize the screen;
- semantic groups require minimum support/confidence;
- old classifier generations force one reclassification;
- retired orphan taxonomy nodes are pruned from the encrypted catalog after reindex.

This is the main guard against replacing Finder folder spam with thousands of AI-generated virtual folders.

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

Treat these as a historical development snapshot, not an SLA or current-commit benchmark. Re-run the harness for performance-sensitive changes.

A 100,000-file run was started during development but did not complete, so the project makes no 100k performance claim.

## One verification gap remains

The implementation now resolves saved bookmarks fail-closed and retains security-scoped leases for live watched roots. What hosted CI cannot create is the genuine App Sandbox extension granted after a human selects a folder in `NSOpenPanel`.

Before calling the app daily-use ready, perform the #44 packaged-app smoke:

1. select a real folder in the packaged app;
2. index it;
3. quit and relaunch;
4. confirm the persisted bookmark restores access;
5. create/change a file and confirm a later FSEvent reindexes it;
6. pause/remove/reauthorize and confirm the old access lifetime is released/replaced correctly.

A green hosted CI run verifies the code paths and synthetic regression suite. It cannot substitute for that one OS-granted permission lifecycle test.
