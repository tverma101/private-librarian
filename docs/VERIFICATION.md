# Verification

This page describes what the current repository actually verifies. A green check is evidence for the exact commit that ran it, not a blanket claim that every host-only macOS workflow has been exercised.

## Source of truth

For a current commit, use a fresh GitHub Actions run plus the host-only packaged-app checks described below. Historical benchmark numbers are comparison data, not release guarantees.

The normal CI workflow has three jobs:

- `test` — repository hygiene, debug build, Swift 6 warnings-as-errors build, the full Swift suite, large-tree regressions, Tier-2/provider contracts, model-runtime/auth/cancellation/memory contracts, clean-Mac bootstrap checks, and vendored SQLCipher provenance;
- `quality` — real sorting acceptance through `Indexer -> SQLCipher Catalog -> SmartOrganizationPlanner`, plus conflict/adjudication tests. It does not grade hand-written predictions as though they were model output;
- `entitlement-audit` — release build, local E2E verification, packaging, and signed packaged-app entitlement audit.

CI runs on `main`, `fix/**`, `feat/**`, `A3`, pull requests, and manual dispatches.

## Reproduce the normal checks

```bash
swift build
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
swift test
```

The product-quality gate can be run directly:

```bash
swift test --filter OrganizationQualityAcceptanceTests
swift test --filter SortingDecisionTests
```

`OrganizationQualityAcceptanceTests` creates a hostile temporary Downloads-style folder, runs the real indexer and encrypted catalog, then asks the production organization planner for Finder destinations. It asserts useful destinations, one primary destination per file, code-vocabulary false-positive resistance, and that contradictory course evidence goes to Review instead of receiving a Finder move.

`SortingDecisionTests` covers specialist adjudication, unresolved-conflict behavior, per-file destination preference, the generic-image escalation boundary, and the rule that similarity/duplicate relationships cannot become Finder plans.

## Measured metric harness

`scripts/benchmark_quality.py` is a **scorer**, not a prediction generator. It requires an input artifact containing predictions produced by a real measured run:

```bash
python3 -B scripts/benchmark_quality.py \
  --input measured-predictions.json \
  --output quality-result.json
```

Running it without `--input` must fail. This prevents CI or documentation from manufacturing a quality score by placing both `truth` and convenient `predicted` answers inside the benchmark itself.

## Sorting-product invariants

The product deliberately separates evidence from a physical organization decision:

1. classification may retain multiple evidence labels;
2. mutually exclusive specialist outputs adjudicate conflicting course, screenshot-subtype, and image-subject lanes;
3. Finder organization elects one primary destination per file using file-specific evidence rather than an alphabetical/global tie;
4. unresolved mutually exclusive conflicts are excluded from every Finder destination and remain available in Review;
5. semantic and near-duplicate groups are relationships only and cannot be materialized as folders;
6. `OrganizationApplier` independently rejects relationship groups even if a future UI regression tries to pass one to the Finder boundary.

Balanced/Quality routing is cheap-first. Generic images whose deterministic baseline confidence is exactly `0.55` are considered unresolved and can reach the bounded VLM fallback. Images with stronger cheap evidence do not run the VLM merely because one is installed.

## Release-style package checks

```bash
swift build -c release
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh --xcode --no-dmg
python3 scripts/audit_entitlements.py \
  .build/package-stage/PrivateLibrarian.app --expect-hardened
```

The production app bundle must contain `LibrarianApp` and must not contain the development `librarian-cli` executable.

Expected packaged entitlements are:

- `com.apple.security.app-sandbox`;
- `com.apple.security.files.user-selected.read-write`;
- `com.apple.security.files.bookmarks.app-scope`;
- `com.apple.security.network.client`.

The app must not have a network-server entitlement, arbitrary/all-files write entitlement, Apple Events automation privilege, or a temporary absolute filesystem exception used as a shortcut.

Analysis remains read-only through `SourceBroker`. Read/write authority exists only because the user can separately review and confirm Apply/Undo inside a folder they selected.

Outbound networking is used only for explicit model provisioning. Production inference workers are separately constrained to local/offline model loading.

## Model/runtime verification

Fast is the zero-download path. Balanced and Quality use public specialist profiles and do not require a Hugging Face account. Optional gated DINOv3 is an advanced separate install and is not a readiness requirement for normal profiles.

On Apple-silicon macOS, setup can bootstrap an app-private CPython runtime when no compatible host Python exists. The bootstrap is pinned to:

- CPython `3.11.16`;
- python-build-standalone release `20260825`;
- SHA-256 `2e50ed6ec49d8714a83c093e9ce74e1b8b21a2c64a49c3b603471d9c4caac76b`.

CI verifies HTTPS-only download intent, checksum verification before use, no `latest` release URL, and no curl-output-to-shell pattern. The runtime and models remain under Private Librarian's Application Support tree.

The current fp16 specialist registry is bounded for the target Mac. Oversized candidates are not exposed by production routing until a separately tested quantized runtime exists. SigLIP semantic vectors and DINO structural/visual vectors remain distinct spaces.

## Large-tree and catalog verification

The Swift suite includes coverage for bounded/streaming discovery, cancellation, safe missing reconciliation, SQL-side bounded views, batched top-K vector scoring, search correctness, exact duplicates, similarity persistence, Review corrections, learned rules, model setup path resolution, catalog encryption/wrong-key refusal, symlink/TOCTOU refusal, Apply journaling, and Undo.

These tests verify algorithmic and security contracts. They are not a substitute for a target-Mac RSS benchmark on an actual large library.

## Host-only acceptance boundaries

Hosted CI cannot manufacture a genuine App Sandbox extension token created by a human choosing a folder through `NSOpenPanel`. Before calling the packaged permission lifecycle release-proven, test on a real packaged app:

1. select a real folder through the system picker;
2. analyze it and verify analysis does not mutate source files;
3. quit/relaunch and verify the security-scoped bookmark restores access;
4. review and Apply one organization plan;
5. verify every move stays inside the selected root and is journaled;
6. Undo and verify restoration;
7. create/change a file and verify the later FSEvent path reindexes it;
8. pause/remove/reauthorize and verify old access leases are released/replaced.

Also perform one clean Apple-silicon packaged-app setup of Balanced or Quality to prove the pinned runtime/public-model bootstrap works inside a consumer sandbox and automatically resumes the requested analysis.

Optional DINOv3 additionally requires upstream account approval if the user explicitly chooses to install it. That is not a normal consumer-profile blocker.

## Interpreting a green CI run

A green exact-head run means the repository compiled, the full regression/security suite passed, the **real temporary-folder organization acceptance** passed, sorting conflict/adjudication tests passed, and the package/entitlement checks passed for that commit.

It does not by itself prove a real persisted `NSOpenPanel` token on the user's host, a completed multi-gigabyte clean consumer setup inside the packaged sandbox, public notarization/stapling, or an unmeasured large-tree performance SLA.
