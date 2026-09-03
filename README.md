# Private Librarian

![CI](https://github.com/tverma101/private-librarian/actions/workflows/ci.yml/badge.svg)

Private Librarian is a native macOS app that indexes folders you choose, understands their contents locally, and gives you a much smaller set of useful virtual groups instead of reorganizing your real filesystem automatically.

**Your original files stay where they are during indexing and analysis.** Search data, categories, similarity families, transcripts, corrections, and learned rules live in an encrypted catalog. The only source-file mutation path is explicit and opt-in: **Apply to Finder** moves selected files inside an authorized root into the reviewed destination plan, journals every move in the encrypted catalog, and supports **Undo Last Apply**.

> **Project status:** alpha / integration testing. The organizer, explicit Apply/Undo path, local-model setup UI, cancellation, large-tree indexing safeguards, and packaged entitlement checks are exercised in CI. A genuine packaged-app smoke using a human-created macOS security-scoped bookmark is still required before calling the permission lifecycle fully release-proven.

## What the app does

- Indexes user-selected folders through a read-only `SourceBroker` analysis boundary.
- Stores writable knowledge in a SQLCipher-encrypted catalog; the catalog key lives in a stable app-owned Keychain item.
- Searches extracted document text, OCR, and local transcripts.
- Skips expensive work for unchanged files and supports cooperative cancellation/pause.
- Streams very large source trees in bounded batches instead of materializing every discovered path in memory.
- Detects exact duplicates and near-duplicate image families without deleting anything.
- Detects screenshots and groups useful subtypes such as code, school/LMS, errors, receipts, conversations, maps, and references.
- Recognizes common course codes and broad code-project evidence.
- Builds semantic similarity families when a compatible local embedding provider is enabled.
- Provides a Review Inbox for uncertain results and catalog-only corrections.
- Learns inspectable, reversible deterministic rules from repeated corrections.
- Watches authorized folders with FSEvents and incrementally refreshes changed files while retaining their security-scoped access leases.
- Offers opt-in local Whisper transcription when a local executable/model passes preflight.
- Can explicitly provision pinned local Hugging Face models from Settings, including gated repositories after the user saves an approved Hugging Face token in macOS Keychain.
- Presents search, Smart Groups, screenshots, school, projects, documents, media, similarity, duplicates, review items, and missing files in a native SwiftUI app.

## Smart Groups: deliberately not 4,902 AI folders

The product is designed around **bounded organization**, not “one folder per model label.”

Raw Vision/model labels never become arbitrary category names. They remain evidence that can be inspected, while automatic image organization uses a small curated vocabulary such as Animals, Vehicles, Scenery, Food, Document photos, and Screenshots.

The Smart Groups screen adds another guardrail:

- at most **18** promoted groups are shown;
- a normal category needs at least **2 files** before it is promoted;
- a semantic group needs at least **3 files** and enough similarity confidence;
- duplicate, screenshot, school, project, semantic, and general groups have separate display limits so one noisy signal cannot take over the screen;
- retired one-off categories from older classifier versions are removed from the encrypted catalog after reclassification;
- the classifier version is part of incremental state, so upgrading to the bounded taxonomy forces one honest refresh and then returns to zero-work skips for unchanged files.

A file may appear in several virtual groups at the same time. For example, one image can be a Screenshot, MAT-171 item, Assignment, and member of a near-duplicate family without being copied into four folders.

## Safety model

The main rule is:

**Analysis is read-only. Files move only through an explicit, reviewed, journaled Apply/Undo operation inside a folder the user granted read/write access to through macOS.**

1. `SourceBroker` owns analysis reads, opens files read-only, rejects unsafe symlink traversal, and never hands a write-capable source handle to a model or parser.
2. Models/parsers receive broker-owned bytes, derived text, feature data, or decoded PCM rather than source filesystem authority.
3. Writable index/search state belongs in the encrypted catalog.
4. Organization is virtual until the user confirms **Apply to Finder**. `OrganizationApplier` is the narrow mutation boundary; it validates destinations against the active security-scoped root, journals moves, and provides Undo.
5. The packaged app has **outbound network-client permission only so an explicit Settings model-install action can reach package/model hosts**. It has no network-server/listener entitlement. Normal indexing and inference force local/offline model loading.
6. Hugging Face credentials supplied in the app are stored in macOS Keychain and passed to the provisioning path over stdin/in-memory rather than argv, shell history, UserDefaults, manifests, or setup logs.
7. Saved folder access fails closed when a security-scoped bookmark cannot be restored. The UI marks that source as needing reauthorization instead of silently falling back to a raw path.

See [`docs/SECURITY.md`](docs/SECURITY.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Requirements

The tested development target is:

- macOS 14 or newer;
- Apple silicon;
- Xcode 16 / Swift Package Manager for development builds.

The default app works without downloaded AI model weights by using Apple Vision and deterministic/local-native paths. Optional Python-backed embedding/VLM models require a compatible Python bootstrap/runtime.

### Current clean-Mac installer limitation

The in-app model installer is real, but the current package **does not yet bundle its own Python distribution by default**. It looks for a usable Python installation to create the isolated model runtime. A pristine consumer Mac without a usable Python may therefore show a setup failure until a compatible runtime is installed or the app is packaged with `--include-runtime`.

Do not describe model provisioning as completely self-contained until a pinned, distributable bootstrap runtime is shipped and verified.

## Quick start

```bash
git clone https://github.com/tverma101/private-librarian.git
cd private-librarian
swift build
swift test
```

For the development app:

```bash
bash script/build_and_run.sh
```

For a release-style sandboxed bundle:

```bash
scripts/package_app.sh --xcode --install
python3 scripts/audit_entitlements.py /Applications/PrivateLibrarian.app --expect-hardened
```

This repository is a Swift package rather than an `.xcodeproj`. The packager uses the `LibrarianApp` SwiftPM scheme through `xcodebuild archive`, stages the archive product into the canonical app bundle, and signs the final bundle. Use `--swiftpm` with an existing release build only when a raw SwiftPM build is needed for a development check.

Packaging emits one versioned `dist/PrivateLibrarian-0.1.0.dmg`. The app is staged under ignored `.build/` output and removed after the DMG is verified, so the installed `/Applications/PrivateLibrarian.app` is the persistent app copy. Add `--install` to install that validated bundle; add `--open` only when you want to launch it. `--no-dmg` without `--install` intentionally leaves a temporary `.build/package-stage/PrivateLibrarian.app` for development checks.

The packager automatically prefers an installed stable Developer ID or Apple Development signing identity so macOS does not treat every rebuild as a new Keychain client. Set `CODESIGN_IDENTITY` explicitly for release signing; an ad-hoc signature is used only when no identity is available. The packager does not invent restricted Keychain-group entitlements without a matching provisioning profile; app-owned catalog and Hugging Face credentials use dedicated generic-password Keychain services instead.

If an older unsigned development build created the catalog item, startup renders first and exposes **Migrate Existing Catalog**. Choose that action and then **Always Allow** once so the same key can be copied into the app-owned item. The CLI is a development/verification tool and is intentionally not shipped inside the packaged app.

## Verification

The branch is checked with:

```bash
swift build
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
swift test
bash scripts/e2e_local.sh "$(swift build --show-bin-path)/librarian-cli"
scripts/package_app.sh --xcode --no-dmg
python3 scripts/audit_entitlements.py .build/package-stage/PrivateLibrarian.app --expect-hardened
```

CI additionally checks:

- source immutability outside the explicit Apply boundary;
- Apply/Undo path containment and journaling;
- symlink/TOCTOU defenses;
- malformed input and prompt-injection fixtures;
- incremental zero-work behavior;
- cancellation, access backoff, bounded discovery, and folder-explosion regressions;
- OCR, screenshots, similarity, media/transcripts, learning, and Smart Group anti-spam behavior;
- SQL-side bounded catalog views and batched top-K vector scoring;
- Hugging Face stdin-only app credential plumbing and secret scans;
- offline-only production inference worker settings;
- packaged read/write bookmark + network-client entitlements while rejecting network-server capability;
- Golden Library quality checks.

The real Whisper test is host-conditional because GitHub-hosted runners do not contain the user's local Whisper executable/model.

See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) for details.

## Optional local models

Apple Vision provides the zero-download OCR/image-analysis layer.

### In the app

Open **Settings → Hugging Face access**:

1. create or paste a Hugging Face access token;
2. accept/request access for gated repositories such as DINOv3 on Hugging Face;
3. save the token in macOS Keychain;
4. choose Fast, Balanced, or Quality;
5. click **Install Selected Models**.

The installer preflights every checkpoint that actually needs downloading before starting large transfers. This means an unapproved gated model fails early rather than after several public models have already downloaded. Downloaded snapshots are pinned to immutable revisions, staged before activation, and recorded with SHA-256 provenance manifests. Normal inference remains local-files-only.

### Terminal fallback

```bash
# Existing `hf auth login` may be used:
./scripts/setup_models.sh --specialist-profile embeddings

# Or keep a token out of argv/history:
printf '%s\n' "$HF_TOKEN" | ./scripts/setup_models.sh --specialist-profile embeddings --hf-token-stdin

# Add the first VLM fallback:
./scripts/setup_models.sh --specialist-profile balanced

# Highest currently supported fp16 stack under the target-Mac execution ceiling:
./scripts/setup_models.sh --specialist-profile quality
```

The current specialist registry includes SigLIP2 So400m NaFlex for semantic image/text space, DINOv3 ViT-B for visual clustering, MiniCPM-V 4.6 as the first generative image fallback, and LFM2.5-VL-3B for explicit Quality mode. On macOS, PaddleOCR-VL is listed as a specialist but skipped because its supported upstream runtime does not cover the target Apple-silicon path; native Vision OCR remains the supported document OCR baseline.

Models above the current fp16 target-Mac execution ceiling are intentionally not exposed by production routing until a separately verified quantized/MLX path exists. Do not add a larger checkpoint to the UI merely because it fits on disk.

Local transcription is opt-in in the app. It only becomes available when the configured local Whisper executable and model pass preflight. Nothing is downloaded silently.

## Remaining host-only release validation

Hosted CI cannot manufacture a genuine App Sandbox extension token created by a human selecting a folder in `NSOpenPanel`, nor can it use the owner's private Hugging Face account approval.

Before calling the app daily-use ready, perform a packaged-app smoke that:

1. selects a real folder through the system picker;
2. indexes it and confirms analysis does not mutate files;
3. reviews and confirms one Apply operation and then Undo;
4. quits and relaunches the packaged app;
5. confirms the saved folder can still be read and remains writable only through explicit Apply;
6. creates/changes a file and confirms a later FSEvent reindexes it;
7. pauses/removes/reauthorizes the folder and confirms old access is released/replaced;
8. saves an approved Hugging Face token in Settings and performs one real gated DINOv3 provisioning smoke.

That is an OS/account acceptance boundary, not something synthetic CI can honestly substitute for.

## Repository map

If you are new to the codebase, start with the [project map](docs/PROJECT_MAP.md). It explains the product flow, SwiftPM targets, feature ownership, and the best place to look for common changes.

For deeper detail, use:

- [Architecture](docs/ARCHITECTURE.md) for module boundaries and design contracts.
- [Security](docs/SECURITY.md) for sandbox, source-access, Keychain, provisioning, and encrypted-catalog rules.
- [Verification](docs/VERIFICATION.md) for local checks and evidence limits.
- [Upstream reuse notes](docs/UPSTREAM_REUSE.md) for research and attribution.
- `ThirdParty/` for vendored code, provenance, and required notices.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Keep pull requests focused, use synthetic fixtures, preserve the read-only analysis boundary, and route source mutations only through the explicit reviewed Apply/Undo path.

Security vulnerabilities should follow [`SECURITY.md`](SECURITY.md) instead of being posted with exploit details in a normal issue.

## License

Private Librarian is licensed under the **Apache License 2.0**. See [`LICENSE`](LICENSE).

Third-party components keep their own licenses and notices under `ThirdParty/`; those notices remain in force for their respective code.
