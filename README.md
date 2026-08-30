# Private Librarian

![CI](https://github.com/tverma101/private-librarian/actions/workflows/ci.yml/badge.svg)

Private Librarian is a native macOS app that indexes folders you choose, understands their contents locally, and gives you a much smaller set of useful virtual groups instead of reorganizing your real filesystem.

**Your original files stay where they are.** Private Librarian does not move, rename, delete, Finder-tag, chmod, or rewrite source files. Search data, categories, similarity families, transcripts, corrections, and learned rules live in an encrypted catalog.

> **Project status:** alpha / integration testing. The main organizer is implemented and exercised in CI. One real packaged-app relaunch smoke test remains for macOS security-scoped bookmark persistence before this should be called a finished daily-use release.

## What the app does

- Indexes user-selected folders through a read-only `SourceBroker` boundary.
- Stores writable knowledge in a SQLCipher-encrypted catalog; the key lives in Keychain.
- Searches extracted document text, OCR, and local transcripts.
- Skips expensive work for unchanged files.
- Detects exact duplicates and near-duplicate image families without deleting anything.
- Detects screenshots and groups useful subtypes such as code, school/LMS, errors, receipts, conversations, maps, and references.
- Recognizes common course codes and broad code-project evidence.
- Builds semantic similarity families when a compatible local embedding provider is enabled.
- Provides a Review Inbox for uncertain results and catalog-only corrections.
- Learns inspectable, reversible deterministic rules from repeated corrections.
- Watches authorized folders with FSEvents and incrementally refreshes changed files.
- Offers opt-in local Whisper transcription when a local executable/model passes preflight.
- Presents search, Smart Groups, screenshots, school, projects, documents, media, similarity, duplicates, review items, and missing files in a native SwiftUI app.

## Smart Groups: deliberately not 4,902 AI folders

The product is designed around **bounded organization**, not “one folder per model label.”

Raw Vision labels never become arbitrary category names. They remain evidence that can be inspected, while automatic image organization uses a small curated vocabulary such as Animals, Vehicles, Scenery, Food, Document photos, and Screenshots.

The Smart Groups screen adds another guardrail:

- at most **18** promoted groups are shown;
- a normal category needs at least **2 files** before it is promoted;
- a semantic group needs at least **3 files** and enough similarity confidence;
- duplicate, screenshot, school, project, semantic, and general groups have separate display limits so one noisy signal cannot take over the screen;
- retired one-off categories from older classifier versions are removed from the encrypted catalog after reclassification;
- the classifier version is part of incremental state, so upgrading to the bounded taxonomy forces one honest refresh and then returns to zero-work skips for unchanged files.

A file may appear in several virtual groups at the same time. For example, one image can be a Screenshot, MAT-171 item, Assignment, and member of a near-duplicate family without being copied into four folders.

## Safety model

The main rule is simple:

**Private Librarian may read selected source files, but it must never modify them.**

1. `SourceBroker` owns source access and opens files read-only with no-follow checks.
2. Models and parsers receive broker-owned bytes, derived text, feature data, or decoded PCM rather than write-capable source handles.
3. Writable state belongs in the encrypted catalog.
4. Organization is virtual; source filesystem layout is not the organizer's output format.
5. The packaged app has no runtime network client/server entitlement, telemetry, or cloud inference dependency.
6. Optional model provisioning is explicit; the app does not silently download model weights.
7. Saved folder access fails closed when its security-scoped bookmark cannot be restored and the UI asks for reauthorization instead of trying a raw path.

See [`docs/SECURITY.md`](docs/SECURITY.md) and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Requirements

The tested development target is:

- macOS 14 or newer;
- Apple silicon;
- Xcode 16 / Swift Package Manager.

The default build does not require downloaded AI model weights. Optional embedding and Whisper backends have separate local provisioning/preflight requirements.

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
swift build -c release
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
```

The CLI is a development/verification tool and is intentionally not shipped inside the packaged app.

## Verification

The integration branch is checked with:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test
swift build -c release
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
```

CI also covers immutability, symlink escape, malformed inputs, prompt-injection data, incremental zero-work behavior, OCR, screenshots, similarity, media/transcripts, learning, live indexing, Smart Group anti-spam behavior, public-repository hygiene, and Golden Library quality checks.

The real Whisper test is host-conditional because GitHub-hosted runners do not contain the user's local Whisper executable/model.

See [`docs/VERIFICATION.md`](docs/VERIFICATION.md) for details.

## Optional local models

Apple Vision provides the zero-download OCR/image-analysis layer.

For the optional Core ML MobileCLIP path:

```bash
python3 scripts/provision_mobileclip_coreml.py --download
scripts/compile_mobileclip_coreml.sh
```

For the optional Python-backed image/text baselines:

```bash
python3 scripts/provision_image_models.py --all
python3 scripts/provision_image_models.py --all --verify-only
```

Local transcription is opt-in in the app. It only becomes available when the configured local Whisper executable and model pass preflight. Nothing is downloaded automatically.

## One remaining release validation

The application now retains security-scoped folder access for the lifetime of live indexing and fails closed when a saved bookmark is missing, stale, or invalid.

What hosted CI cannot manufacture is a genuine App Sandbox extension token created by a human selecting a folder in `NSOpenPanel`. Before calling the app daily-use ready, perform one packaged-app smoke test that:

1. selects a real folder;
2. indexes it;
3. quits and relaunches the packaged app;
4. confirms the saved folder can still be read;
5. creates/changes a file and confirms a later FSEvent reindexes it;
6. confirms pausing/removing/reauthorizing the folder releases/replaces access correctly.

That final OS-level check is tracked in issue #44.

## Repository map

- `Sources/LibrarianCore/` — indexing, catalog, OCR, smart organization, similarity, media, learning, and provider logic.
- `Sources/LibrarianApp/` — native SwiftUI app.
- `Sources/librarian-cli/` — development/verification CLI.
- `Tests/LibrarianTests/` — safety, behavior, resilience, media, search, organization, and quality tests.
- `scripts/` — packaging, verification, provisioning, benchmarks, and helper processes.
- `docs/ARCHITECTURE.md` — system architecture.
- `docs/SECURITY.md` — threat model and security boundaries.
- `docs/VERIFICATION.md` — verification commands and receipts.
- `docs/UPSTREAM_REUSE.md` — upstream research and attribution notes.
- `ThirdParty/` — vendored third-party code, provenance, and required notices.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Keep pull requests focused, use synthetic fixtures, and preserve the read-only/offline boundaries.

Security vulnerabilities should follow [`SECURITY.md`](SECURITY.md) instead of being posted with exploit details in a normal issue.

## License

Private Librarian is licensed under the **Apache License 2.0**. See [`LICENSE`](LICENSE).

Third-party components keep their own licenses and notices under `ThirdParty/`; those notices remain in force for their respective code.
