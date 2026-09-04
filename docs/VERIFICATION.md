# Verification

This page describes how to verify the current repository and how to interpret development measurements.

## Source of truth

For a current commit, a fresh GitHub Actions run plus any required host-only macOS/distribution smoke is the source of truth. Historical benchmark numbers are comparison data, not release guarantees. A private account smoke is relevant only to an optional explicitly selected gated model such as DINOv3; it is not part of the normal Fast/Balanced/Quality acceptance path.

The normal CI workflow has three jobs:

- `test` — repository hygiene, debug build, Swift 6 warnings-as-errors build, the full Swift suite, large-tree regressions, Tier-2/provider contracts, public-profile and optional gated-auth contracts, pinned clean-Mac runtime-bootstrap checks, and vendored SQLCipher provenance;
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
- model-setup Application Support path resolution and optional Keychain token validation.

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

Why network client? The user can explicitly start model setup from the main Analyze flow or Settings. That provisioning action needs outbound access to the pinned runtime/model hosts. Normal inference is separately constrained to local/offline loading, and the app has no inbound/listener entitlement.

A blanket deny-network probe is therefore no longer an accurate packaged-app acceptance test. The relevant checks are:

1. entitlement audit proves no server/listener permission;
2. model-runtime CI proves production inference forces local/offline loading;
3. source review keeps network-capable behavior isolated to explicit provisioning/system browser links.

## Consumer profile provisioning verification

The normal `embeddings`, `balanced`, and `quality` setup profiles are deliberately **public-only**. A consumer must not need a Hugging Face account, access request, token, or license-approval detour merely to use the recommended local mode.

`scripts/test_specialist_contract.py` imports the production provisioner and asserts that every normal profile excludes every registry entry marked `gated`. DINOv3 stays registered as a supported optional advanced model, but it is not selected by any normal profile and it is not part of Balanced/Quality readiness.

Normal Terminal setup therefore needs no credential:

```bash
./scripts/setup_models.sh --specialist-profile embeddings
./scripts/setup_models.sh --specialist-profile balanced
./scripts/setup_models.sh --specialist-profile quality
```

The provisioner resolves the pinned revisions for all public checkpoints that actually need downloading before the first large transfer. Downloaded snapshots are staged before activation and recorded with SHA-256 provenance manifests.

## Optional gated-model credential verification

An explicitly selected gated model still uses the stricter credential path. For example, optional DINOv3 may be installed separately after the user has upstream approval:

```bash
printf '%s\n' "$HF_TOKEN" | ./scripts/setup_models.sh \
  --specialist-model dinov3-vitb16-lvd1689m --hf-token-stdin
```

The optional in-app/advanced credential contract is:

```text
macOS Keychain
    ↓ explicit advanced install action
Swift model setup / setup helper
    ↓ stdin
provision_specialist_models.py
    ↓ in-memory token argument
huggingface_hub
```

CI checks that:

- `--hf-token-stdin` exists in both setup layers;
- an app-supplied token is not re-exported as a child environment variable;
- token-like secrets are not tracked in the repository;
- provisioning code passes the in-memory token explicitly to Hub API/download calls;
- inference workers retain `local_files_only=True` / offline Hub settings.

A real optional DINOv3 smoke still requires a private user token tied to an account with upstream approval. Hosted CI cannot honestly provide that approval, but this is no longer a consumer-profile or daily-use release blocker.

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

The consumer specialist stack is intentionally bounded for the target Mac. Normal profiles use public SigLIP2 plus the public bounded VLM fallbacks appropriate to the selected quality level. Native Apple Vision remains the supported OCR/visual baseline. Optional DINOv3 adds a separate visual-similarity representation only when explicitly provisioned.

The production fp16 registry rejects known larger candidates from normal routing until a separately tested quantized/MLX runtime exists. A checkpoint fitting on disk is not sufficient evidence that it is safe to expose in the current execution path.

PaddleOCR-VL is reported but skipped on the current macOS target path; Apple Vision OCR is the supported baseline there.

### Clean-Mac Python bootstrap

On Apple-silicon macOS, model setup does not depend on Homebrew, Xcode, or a preinstalled global Python. If the app-private model runtime is absent and no compatible host Python is available, `setup_models.sh` downloads one exact `python-build-standalone` archive into the app's Application Support tree.

The bootstrap is deliberately narrow:

- CPython version `3.11.16`;
- upstream dated release `20260825`;
- Apple-silicon `install_only` archive only;
- repository-pinned SHA-256 `2e50ed6ec49d8714a83c093e9ce74e1b8b21a2c64a49c3b603471d9c4caac76b`;
- HTTPS-only `curl` invocation with no pipe to a shell;
- archive checksum verified with `/usr/bin/shasum -a 256` before extraction/use;
- extracted runtime stays inside Private Librarian's Application Support tree.

CI syntax-checks the helper and asserts the exact version, dated release, digest, checksum verification, HTTPS restriction, no `latest` release URL, and no curl-pipe-shell pattern. Ordinary CI intentionally does not re-download the large runtime/dependency/model stack on every commit.

Automatic runtime bootstrap currently targets Apple-silicon macOS. Intel hosts must provide a compatible Python 3.10+ via `LIBRARIAN_BOOTSTRAP_PYTHON` or use a package containing an appropriate runtime.

A real **packaged sandbox** clean-user-account smoke remains required before calling this distribution path release-proven: hosted CI verifies the supply-chain contract and package entitlements, but does not perform the full external runtime + multi-gigabyte public-model install inside a consumer App Sandbox on every run.

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

These tests prove the intended algorithmic memory shape. They are not a substitute for a completed large real-library RSS benchmark on the target machine.

## Security-scoped bookmark verification

Synthetic tests can verify fail-closed bookmark resolution, lease ownership, cancellation wiring, and Apply containment. Hosted CI cannot manufacture a genuine App Sandbox extension token created when a human selects a folder through `NSOpenPanel`.

Before calling the permission lifecycle daily-use ready, perform a packaged-app smoke:

1. select a real folder through the system picker;
2. analyze it and verify analysis does not alter source bytes/metadata unexpectedly;
3. review and confirm one Apply operation;
4. verify the move is inside the selected root and is journaled;
5. Undo Last Apply and verify restoration;
6. quit and relaunch the packaged app;
7. verify the persisted bookmark restores access;
8. create/change a file and verify a later FSEvent reindexes it;
9. pause/remove/reauthorize and verify old access leases are released/replaced.

That smoke is the evidence needed for the OS-granted permission lifecycle. A green hosted CI run cannot substitute for it.

For the complete daily-use acceptance path, also switch from Fast to Balanced on a clean Apple-silicon account and verify the **account-free** in-app pinned runtime/public-model setup completes and resumes the requested analysis automatically.

## SQLCipher provenance

SQLCipher is vendored under `ThirdParty/sqlcipher/` with license and provenance files. CI checks the expected source/provenance so an accidental system SQLite fallback does not go unnoticed. Catalog tests also verify encrypted-on-disk behavior and wrong-key failure.

## Interpreting CI receipts

A green current run means the code compiled, the synthetic/regression suite passed, the package assembled, and its entitlement/runtime contracts matched the repository assertions for that exact commit.

It does **not** by itself prove:

- a genuine persisted `NSOpenPanel` security-scope token works after relaunch on the user's host;
- the full pinned Python/dependency/public-model bootstrap has completed successfully inside a clean consumer packaged sandbox;
- an optional gated-model account has upstream approval;
- public distribution is notarized/stapled unless the release process explicitly performed those steps;
- large-tree performance meets an SLA that was never benchmarked on that exact commit/hardware.

Keep those boundaries explicit rather than turning an old successful receipt into a broader release claim.
