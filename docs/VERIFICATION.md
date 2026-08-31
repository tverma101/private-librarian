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
bash scripts/e2e_local.sh "$(swift build --show-bin-path)/librarian-cli"
scripts/package_app.sh --xcode --install
python3 scripts/audit_entitlements.py /Applications/PrivateLibrarian.app --expect-hardened
python3 scripts/test_model_provisioning.py
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
- scalable streaming discovery, deterministic large-directory traversal,
  max-files early stop, SQL-backed missing reconciliation, inaccessible-root
  backoff, cancellation/pause outcomes, project semantic summaries, bounded
  semantic fanout, and top-K vector search.

The real provisioned Whisper test is host-conditional. Hosted CI does not ship the user's local Whisper executable/model, so that test is expected to skip there while generated-fixture media tests still exercise the production indexing pipeline.

## Concurrency checking

The integration branch is also built with:

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
```

This is the regression gate for the app-model callback problem previously tracked in #46. Background indexing remains off the main actor while progress/completion handoff is actor-aware.

## Packaging and sandbox checks

`scripts/package_app.sh` archives the `LibrarianApp` SwiftPM scheme with
`xcodebuild`, stages the archive product under ignored `.build/` output with
the app metadata and sandbox entitlements, signs the final bundle with the
configured identity (automatically preferring a stable local Developer ID or
Apple Development identity, with ad-hoc as the fallback), and emits a versioned
`dist/PrivateLibrarian-VERSION.dmg`. The temporary app is removed after DMG
verification (or after `--install`), leaving one persistent installed app. The archive is generic
macOS and therefore produces a distributable universal executable on the
current host. It includes SwiftPM resources, the offline helper, and no CLI
executable. `--swiftpm` remains available for packaging an existing raw
SwiftPM release build. `--include-models` and `--include-runtime` are explicit
opt-ins for a same-host offline bundle; the normal DMG keeps large,
user-specific model weights in Application Support.

For the final signed bundle, the packager uses the stable certificate and
bundle identifier but does not invent restricted application-identifier or
Keychain-group entitlements without a matching provisioning profile. The
data-protection Keychain therefore remains in the app's default sandbox
namespace. The GUI first queries that app-owned item. If a legacy
login-keychain item from an old unsigned CLI is present, startup renders first
and exposes **Migrate Existing Catalog**; only that explicit action can require
one macOS approval. The same key is then copied into the new item and future
launches do not query the legacy ACL. The CLI never accesses the GUI item and
uses `LIBRARIAN_CATALOG_KEY` for headless catalog checks.

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

The supported Python setup is:

```bash
./scripts/setup_models.sh
python3 scripts/provision_image_models.py --list \
  --models-dir "$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models"
"$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/model-runtime/bin/python3" \
  scripts/embed.py --check
```

The setup script downloads only the two models consumed by `scripts/embed.py`
at immutable revisions. It uses a temporary sibling directory, verifies every
downloaded file, writes `provenance.json`, and renames the completed directory
into place. Existing incomplete or superseded directories are preserved with
a `.previous-*` name. The app sets the Hugging Face and Transformers offline
flags for every helper process.

The specialist setup is separate and explicit:

```bash
./scripts/setup_models.sh --specialist-profile embeddings
./scripts/setup_models.sh --specialist-profile balanced
SPECIALIST_PYTHON="$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/model-runtime/bin/python3"
LIBRARIAN_SPECIALIST_MODELS_DIR="$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models/specialists" \
  "$SPECIALIST_PYTHON" scripts/specialist.py --check
"$SPECIALIST_PYTHON" scripts/specialist.py --runtime-check siglip2-so400m-naflex
python3 scripts/test_specialist_contract.py
```

The embeddings profile is the recommended macOS baseline. Balanced and quality
are larger explicit downloads; quality is never automatic. PaddleOCR-VL is
reported and skipped on macOS because its [upstream runtime documentation](https://paddlepaddle.github.io/PaddleX/3.3/en/pipeline_usage/tutorials/ocr_pipelines/PaddleOCR-VL.html)
currently excludes CPU and Arm, so this app uses native Vision OCR there. A
specialist `--check` is structural and offline; the app's specialist preflight
also imports the required runtime modules before enabling a provider. A
verified checkpoint is not downloaded again unless `--force` is supplied.

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

## Current local audit receipt

On 2026-08-30, the integrated PR #57 review checkout passed the full local
Swift suite with 169 tests and 0 failures after the scalable discovery,
semantic-compaction, access-backoff, cancellation, Keychain lifecycle, and
specialist-router changes. The specialist bridge tests cover configured-root
selection, exact-manifest rejection, and the unsupported macOS Paddle path;
the specialist contract fixture suite passed separately. Targeted live
coordinator coverage passed all 19 tests. The scale receipts use synthetic
data: a 5,000-file large-directory traversal, bounded discovery batches, and
the existing 100,000-event live-storm test. No 24 GB browser-tree RSS run was
completed in this audit, so the project does not claim that benchmark.

The Xcode-backed packaging path also passed: `xcodebuild archive` produced a
generic macOS universal (`arm64` + `x86_64`) `LibrarianApp` executable and dSYM;
the final staged app and `/Applications/PrivateLibrarian.app` were signed with
the stable local Apple Development identity, retained only the profile-free
sandbox/read-only entitlements, passed deep verification and the entitlement
audit, and produced a verified versioned DMG. The old
login-keychain item was inspected and confirmed to reference the removed
`librarian-cli` code identity; the old catalog files were copied into the
sandbox container without modifying the originals. The installed app was not
visually inspected through Computer Use in this run, and the one-time legacy
Keychain approval was not user-confirmed, so a prompt-free post-migration launch
is not claimed yet. Public distribution still requires a Developer ID
Application identity, notarization, and stapling.

## Current merged-release and headless install receipt

On 2026-08-31, PR #57 was confirmed merged into `fix/tier2-incremental-ci` at
`48d4d7789d24ee1486a4f2ed5868f5a0b04879b5`. The canonical post-merge package
was rebuilt with `scripts/package_app.sh --xcode --install`. The package now
compiles the checked-in `AppIcon` asset catalog and verifies both
`Contents/Resources/Assets.car` and `Contents/Resources/AppIcon.icns`; the
bundle also declares `CFBundleIconName=AppIcon` and `CFBundleIconFile=AppIcon`.

The installed artifact passed strict code-sign verification, the entitlement
audit, universal-slice inspection, DMG checksum verification, and a read-only
DMG mount check. The final DMG SHA-256 was
`ac30e488a934637a51995a2add79e53c0e575c0c553ff736b9a9e67b9f99edd4`.
`dist/` contains only the versioned DMG, `/Applications` contains exactly one
Private Librarian bundle, and the production app contains no CLI executable.

The installed app was reviewed headlessly with an explicit isolated
`open -n -g` launch. `LibrarianApp` remained alive for the smoke window and
exited cleanly when only the task-created PID was terminated; recent process
logs contained no crash, fatal, catalog, migration, or repeated-Keychain
failure. LaunchServices had five stale registrations for old temporary/archive
bundles; unregistering those exact paths left only
`/Applications/PrivateLibrarian.app`. No default app handler or file
association was changed. The local Apple Development artifact is still not
notarized/stapled, so `spctl` rejection is a public-distribution boundary, not
an installed-app launch failure.
