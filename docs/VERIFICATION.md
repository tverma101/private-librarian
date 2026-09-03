# Verification

This page describes how to verify the current repository and how to interpret development measurements.

## Source of truth

For a current commit, a fresh GitHub Actions run plus any required host-only macOS/account smoke is the source of truth. Historical benchmark numbers are comparison data, not release guarantees.

The normal CI workflow has three jobs:

- `test` — repository hygiene, debug build, Swift 6 warnings-as-errors build, the full Swift suite, large-tree regressions, Tier-2/provider contracts, Hugging Face auth/runtime checks, and vendored SQLCipher provenance;
- `quality` — deterministic Golden Library metric/schema checks;
- `entitlement-audit` — release build, local E2E verification, packaging, and signed packaged-app entitlement audit.

CI runs on `main`, `fix/**`, `feat/**`, pull requests, and manual dispatches. Branch hardening therefore has to pass the same workflow instead of relying on old receipts from another branch.

## Reproduce the normal checks

```bash
swift build
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
swift test
```

For the release-style path:

```bash
swift build -c release
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh --xcode --no-dmg
python3 scripts/audit_entitlements.py \
  .build/package-stage/PrivateLibrarian.app --expect-hardened
```

Quality/performance harnesses:

```bash
python3 -B scripts/benchmark_quality.py --output quality-result.json
python3 scripts/benchmark_librarian.py --files 10000 --search-iters 5 --relation-iters 3
```

## What the Swift suite covers

The suite includes coverage for:

- read-only analysis-source behavior;
- explicit Apply/Undo containment, journaling, and regression cases;
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
- bounded Smart Groups, raw-label suppression, lane diversity limits, and legacy taxonomy pruning;
- scalable streaming discovery and deterministic large-directory traversal;
- max-files early stop and SQL-backed missing reconciliation;
- inaccessible-root backoff and reauthorization state;
- cancellation/pause/remove/replacement outcomes;
- project semantic summaries and bounded semantic fan-out;
- SQL-side bounded views and batched top-K vector scoring;
- model-setup Application Support path resolution and Keychain token validation.

The real provisioned Whisper test is host-conditional. Hosted CI does not ship the user's local Whisper executable/model, so that integration cannot be promoted to a universal CI guarantee.

## Packaging and sandbox checks

`scripts/package_app.sh` archives the `LibrarianApp` SwiftPM scheme with `xcodebuild`, stages the archive product under ignored `.build/` output with app metadata and entitlements, signs the final bundle with the configured identity, and optionally emits a versioned DMG.

The CLI is a development/verification tool and must not be copied into the production app bundle.

### Expected packaged entitlements

The current product requires:

- `com.apple.security.app-sandbox`;
- `com.apple.security.files.user-selected.read-write`;
- `com.apple.security.files.bookmarks.app-scope`;
- `com.apple.security.network.client`.

The product must **not** have:

- `com.apple.security.network.server`;
- arbitrary/all-files write entitlements;
- Apple Events automation privilege;
- privileged filesystem operations;
- temporary absolute read/write exceptions introduced as a shortcut.

Why read/write? Analysis itself remains read-only through `SourceBroker`, but the user can explicitly confirm **Apply to Finder** and later Undo inside a folder they selected. A read-only sandbox entitlement would make that advertised feature fail in the real packaged app.

Why network client? The user can explicitly press **Install Selected Models** in Settings. That provisioning action needs outbound access. Normal inference is separately constrained to local/offline loading, and the app has no inbound/listener entitlement.

A blanket deny-network probe is therefore no longer an accurate packaged-app acceptance test. The relevant checks are:

1. entitlement audit proves no server/listener permission;
2. model-runtime CI proves production inference forces local/offline loading;
3. source review keeps network-capable behavior isolated to explicit provisioning/system browser links.

## Hugging Face provisioning verification

The app supports gated Hugging Face repositories without requiring the user to paste a token into a Terminal command.

The in-app credential contract is:

```text
macOS Keychain
    ↓ explicit Install action
Swift model setup
    ↓ stdin
setup_models.sh
    ↓ stdin
provision_specialist_models.py
    ↓ in-memory token argument
huggingface_hub
```

CI checks that:

- `--hf-token-stdin` exists in both setup layers;
- the app-supplied token is not re-exported as a child environment variable;
- token-like secrets are not tracked in the repository;
- provisioning code passes the in-memory token explicitly to Hub API/download calls;
- inference workers retain `local_files_only=True` / offline Hub settings.

The specialist provisioner resolves every checkpoint that actually requires download **before** the first large transfer. If DINOv3 access was not approved for the account, provisioning should fail at preflight rather than first downloading several gigabytes of public checkpoints.

A real gated-model smoke still requires a private user token tied to an account with upstream DINOv3 access. Hosted CI cannot honestly provide that approval.

## Model storage path verification

The packaged app resolves Application Support through Foundation:

```swift
FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
```

It must not build a container path by appending `Library/Containers/...` to `$HOME`. Inside App Sandbox, `$HOME` already refers to the container home; doing so creates a nested bogus container path and can make a successful setup invisible to runtime checks.

The model setup process receives exact `LIBRARIAN_APP_SUPPORT_DIR`, `LIBRARIAN_MODELS_DIR`, `LIBRARIAN_SPECIALIST_MODELS_DIR`, and `LIBRARIAN_MODEL_RUNTIME_DIR` values derived from that Foundation URL. **Open Models Folder** uses the same resolved model root.

`HuggingFaceModelSetupTests` protects this regression.

## Optional provider/model checks

Apple Vision is the zero-download baseline.

Terminal specialist setup remains available:

```bash
# Use normal `hf auth login` state if desired:
./scripts/setup_models.sh --specialist-profile embeddings

# Or keep a token out of argv/history:
printf '%s\n' "$HF_TOKEN" \
  | ./scripts/setup_models.sh --specialist-profile embeddings --hf-token-stdin

./scripts/setup_models.sh --specialist-profile balanced
./scripts/setup_models.sh --specialist-profile quality
python3 scripts/test_specialist_contract.py
```

The current production fp16 specialist registry is intentionally bounded for the target Mac. CI rejects known larger candidates from production routing until a separately tested quantized/MLX runtime exists. A checkpoint fitting on disk is not sufficient evidence that it is safe to expose in the current execution path.

PaddleOCR-VL is reported but skipped on the current macOS target path; Apple Vision OCR is the supported baseline there.

### Python bootstrap limitation

The default release does not yet ship its own Python distribution. In-app model setup needs a usable host Python to create the isolated runtime unless the package was explicitly built with a compatible runtime included.

A pristine consumer Mac without usable Python is therefore a real remaining distribution boundary. Do not label model setup “self-contained on every Mac” until a pinned bootstrap runtime is shipped and verified.

## Large-tree verification

The current branch contains explicit scale controls rather than relying on a small-fixture extrapolation:

- bounded discovery batches;
- external-sort handling for very large sibling sets;
- catalog scan generations rather than a full in-memory seen-path set;
- cancellation between safe file/stage boundaries;
- no destructive missing reconciliation after cancelled/partial/unavailable scans;
- persisted access backoff with bounded in-memory prefix state;
- one similarity rebuild per completed scan instead of per discovery batch;
- SQL-side bounded file/similarity pages;
- vector-table batches with only top-K retained in Swift memory.

These tests prove the intended algorithmic memory shape. They are not a substitute for a completed 24-GB browser-checkout RSS benchmark on the target machine.

## Security-scoped bookmark verification

Synthetic tests can verify fail-closed bookmark resolution, lease ownership, cancellation wiring, and Apply containment. Hosted CI cannot manufacture a genuine App Sandbox extension token created when a human selects a folder through `NSOpenPanel`.

Before calling the permission lifecycle daily-use ready, perform a packaged-app smoke:

1. select a real folder through the system picker;
2. index it and verify analysis does not alter source bytes/metadata unexpectedly;
3. review and confirm one Apply operation;
4. verify the move is inside the selected root and is journaled;
5. Undo Last Apply and verify restoration;
6. quit and relaunch the packaged app;
7. verify the persisted bookmark restores access;
8. create/change a file and verify a later FSEvent reindexes it;
9. pause/remove/reauthorize and verify old access leases are released/replaced.

That smoke is the evidence needed for the OS-granted permission lifecycle. A green hosted CI run cannot substitute for it.

## SQLCipher provenance

SQLCipher is vendored under `ThirdParty/sqlcipher/` with license and provenance files. CI checks the expected source/provenance so an accidental system SQLite fallback does not go unnoticed. Catalog tests also verify encrypted-on-disk behavior and wrong-key failure.

## Interpreting CI receipts

A green current run means the code compiled, the synthetic/regression suite passed, the package assembled, and its entitlement/runtime contracts matched the repository assertions for that exact commit.

It does **not** by itself prove:

- a genuine persisted `NSOpenPanel` security-scope token works after relaunch on the user's host;
- the user's Hugging Face account has actually been approved for a gated repository;
- a pristine Mac without Python can bootstrap the optional Python model runtime;
- public distribution is notarized/stapled unless the release process explicitly performed those steps;
- large-tree performance meets an SLA that was never benchmarked on that exact commit/hardware.

Keep those boundaries explicit rather than turning an old successful receipt into a broader release claim.
