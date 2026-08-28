# Private Librarian

![CI](https://github.com/tverma101/private-librarian/actions/workflows/ci.yml/badge.svg)

Private Librarian is a native macOS app that indexes files you choose, understands their contents locally, and organizes them through an encrypted virtual catalog.

It does **not** reorganize your real folders on disk. Source files stay read-only; categories, relationships, duplicate families, review decisions, and search data live in the app's catalog instead.

> **Project status:** alpha. The core safety model and a large part of the organizer are implemented and tested, but a few app-level permission and media-integration issues still need to be fixed before this should be treated as a finished daily-use release.

## What works today

- Read-only indexing of user-selected folders.
- SQLCipher-encrypted catalog with the key stored in Keychain.
- Full-text search over extracted text and transcripts.
- Incremental indexing: unchanged files skip expensive analysis.
- Exact duplicate detection without deleting anything.
- Screenshot detection, OCR, subtype classification, and virtual screenshot groups.
- Near-duplicate and semantic similarity families.
- Multi-label virtual organization and an organization graph.
- Review Inbox for uncertain classifications and catalog-only corrections.
- Evidence-backed local learning rules that stay inspectable and reversible.
- FSEvents-based live change detection with coalescing and safe reconciliation.
- Local Vision OCR and image analysis.
- Optional local embedding providers, including a Core ML MobileCLIP path.
- Broker-safe media probing, PCM decoding, transcript storage, and a local Whisper adapter.
- Native SwiftUI dashboard for search, screenshots, duplicates, review items, media, and virtual groups.
- Security, immutability, symlink, resilience, quality, and incremental-indexing tests in CI.

## The safety model

The most important rule in this repository is simple:

**Private Librarian may read selected source files, but it must never modify them.**

The implementation is built around that rule:

1. `SourceBroker` owns source-file access and opens files read-only with no-follow checks.
2. Analysis code receives broker-owned bytes, derived text, feature data, or decoded PCM instead of write-capable source handles.
3. The writable state is the encrypted SQLCipher catalog.
4. Organization is virtual. The app does not move, rename, delete, Finder-tag, chmod, or rewrite source files.
5. Runtime inference is local. The packaged app has no runtime network entitlement, telemetry, or cloud model dependency.
6. Optional model downloads happen only through explicit provisioning scripts run by the user; the app does not silently download models.

See [`docs/SECURITY.md`](docs/SECURITY.md) for the threat model and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the design.

## Current alpha gaps

The main remaining blockers are tracked as normal issues:

- [#42](https://github.com/tverma101/private-librarian/issues/42) — re-index media when the ASR provider or model changes.
- [#43](https://github.com/tverma101/private-librarian/issues/43) — distinguish transcription failure from a valid no-transcript result and retry safely.
- [#44](https://github.com/tverma101/private-librarian/issues/44) — keep security-scoped folder permission active for live indexing in the sandboxed app.
- [#45](https://github.com/tverma101/private-librarian/issues/45) — fail closed when a saved folder bookmark cannot be restored.
- [#46](https://github.com/tverma101/private-librarian/issues/46) — remove Swift 6 concurrency warnings in the app model.
- [#47](https://github.com/tverma101/private-librarian/issues/47) — expose the implemented local transcription backend through the actual app settings.

These are why the integration pull request remains a draft even though the current CI suite is green.

## Requirements

The tested development target is:

- macOS 14 or newer;
- Apple silicon;
- Xcode 16 / Swift Package Manager.

Optional Python-backed model providers need Python and their local dependencies. They are not required for the default build or test suite.

## Quick start

Clone the repository and run the normal Swift build/tests:

```bash
git clone https://github.com/tverma101/private-librarian.git
cd private-librarian
swift build
swift test
```

For a development app bundle:

```bash
bash script/build_and_run.sh
```

For the sandboxed release-style bundle and entitlement audit:

```bash
swift build -c release
scripts/package_app.sh .build/release
scripts/audit_entitlements.py dist/PrivateLibrarian.app
```

The CLI is a development and verification tool. It is intentionally not shipped inside the packaged app.

## Verification

The integrated branch currently has a green GitHub Actions run with 116 tests, 0 failures, and 1 host-conditional Whisper test skipped because the hosted runner does not have the local Whisper model/runtime installed.

Useful local checks include:

```bash
swift test
bash scripts/e2e_local.sh
scripts/package_app.sh .build/release
scripts/audit_entitlements.py dist/PrivateLibrarian.app
python3 scripts/benchmark_quality.py
python3 scripts/benchmark_librarian.py
```

More detailed receipts and test coverage live in [`docs/VERIFICATION.md`](docs/VERIFICATION.md).

## Optional local models

Private Librarian works without downloaded model weights. Apple Vision is the default zero-download image/OCR layer.

For the optional Core ML MobileCLIP path:

```bash
python3 scripts/provision_mobileclip_coreml.py --download
scripts/compile_mobileclip_coreml.sh
```

For the optional Python image/text baseline:

```bash
python3 scripts/provision_image_models.py --all
python3 scripts/provision_image_models.py --all --verify-only
```

Provisioned model directories are gitignored. Providers must pass local preflight/provenance checks before activation.

The Whisper adapter is implemented in the core, but app-level user configuration is still tracked in #47.

## Repository map

- `Sources/LibrarianCore/` — indexing, catalog, OCR, similarity, media, learning, and provider logic.
- `Sources/LibrarianApp/` — native SwiftUI app.
- `Sources/librarian-cli/` — development/verification CLI.
- `Tests/LibrarianTests/` — safety, behavior, resilience, media, search, and quality tests.
- `scripts/` — packaging, verification, provisioning, benchmarks, and helper processes.
- `docs/ARCHITECTURE.md` — system architecture.
- `docs/SECURITY.md` — threat model and security boundaries.
- `docs/VERIFICATION.md` — verification details and receipts.
- `docs/UPSTREAM_REUSE.md` — upstream research and reuse notes.
- `ThirdParty/` — vendored third-party code, provenance, and required notices.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Keep changes focused, keep fixtures synthetic, and preserve the read-only/offline boundaries.

Security vulnerabilities should follow [`SECURITY.md`](SECURITY.md) rather than being posted with exploit details in a normal issue.

## License

A project-level license has **not** been selected yet. The owner decision is tracked in [#48](https://github.com/tverma101/private-librarian/issues/48).

Third-party components keep their own licenses and notices under `ThirdParty/`. Those notices must remain intact regardless of the eventual project license.
