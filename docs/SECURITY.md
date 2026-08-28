# Security model

## The short version

Private Librarian may read files inside folders the user authorizes, but it must never modify those source files. All organization, search data, corrections, relationships, and learned rules live in a separate encrypted catalog.

The packaged app is also intended to run without runtime network access. Optional local model provisioning is a separate, explicit setup step rather than something the app silently does in the background.

## Hard boundaries

### Source files are read-only

`SourceBroker` is the source-access boundary. It opens regular files read-only, rejects symlink traversal, and checks file identity again after reads so a changed or replaced file is not silently accepted as the same generation.

The source subsystem must not gain APIs for:

- writing or truncating files;
- moving, renaming, or deleting files;
- Finder tags or xattrs;
- chmod/chown-style permission changes;
- handing a write-capable file handle to a model or parser.

### The catalog is the writable layer

The catalog is SQLCipher-encrypted and its key is stored in Keychain. Virtual categories, search text, embeddings, transcript rows, duplicate/similarity relationships, review state, and user corrections belong there.

Deleting or rebuilding the catalog must not alter originals.

### Models do not own filesystem authority

Image/text models receive broker-owned image bytes or derived text. Speech providers receive decoded PCM. A model provider should not receive the original source path as an instruction to reopen the user's file.

Model artifacts live outside authorized source roots and require local preflight/provenance checks before activation.

### Runtime stays local

The packaged application is audited for sandbox entitlements and is expected to have no network client/server entitlement. The network-negative verification probe also checks DNS/TCP/HTTP, LAN, localhost, and listen attempts.

Provisioning scripts may use the network only when the user explicitly runs a download command. That is separate from normal app runtime.

## Threats and current controls

| Threat | Current control / status | Main verification |
|---|---|---|
| A bug or hostile document causes a source-file change | Source subsystem exposes read-only access; organization is catalog-only | Immutability tests, Review Inbox tests |
| Symlink escapes the selected tree | Enumeration does not descend through symlinks; direct reads use no-follow checks and an `openat` walk | `SymlinkEscapeTests` |
| File is swapped while being read | Broker checks the opened file and final path generation before accepting the read | changed-during-read / TOCTOU tests |
| Malformed input crashes the whole index | Work is bounded and failures are isolated per file | `ResilienceTests`, OCR/media malformed fixtures |
| Catalog is readable as plain SQLite | SQLCipher is compiled into the binary; on-disk encryption and wrong-key behavior are tested | catalog encryption tests, E2E checks |
| App silently links an unencrypted SQLite fallback | CI verifies the vendored SQLCipher source/provenance and packaged behavior | CI + `docs/VERIFICATION.md` |
| Hostile classifier output smuggles paths/actions | Classifier output must pass the schema/contract validator; document content is treated as data | `PromptInjectionTests` |
| Duplicate cleanup deletes a real file | Duplicate handling is report/virtual-state only; there is no delete API in the detector | `BehaviorTests` |
| Missing or pending content appears as current search data | Search joins against current indexed catalog state; changed generations are committed transactionally | search/media regression tests |
| Decoder sees a truncated compressed container | Complete-snapshot API either supplies a complete bounded container or rejects it; parsers are not fed a silent prefix | OCR/media snapshot tests |
| Model/helper receives source filesystem authority | Image providers receive bytes/text; ASR receives PCM; helper payloads travel over stdin rather than source-path argv | Tier-2/media integration tests |
| Optional embedding helper phones home at runtime | Local model bridge uses offline/local-files-only settings and packaged app has no runtime network entitlement | provider preflight + network-negative probe |
| Unverified native model artifacts activate | Core ML MobileCLIP requires the expected compiled pair, tokenizer data, and pinned provenance before preflight succeeds | provider smoke/preflight tests |
| A changed ASR provider/model leaves an old unchanged file unprocessed | **Open issue #42.** ASR on/off state is versioned, but provider/model identity still needs to participate in incremental invalidation | tracked blocker |
| A temporary ASR failure is mistaken for a valid empty result | **Open issue #43.** Provider results need explicit success/no-transcript/failure semantics | tracked blocker |
| Live indexing loses access to a user-selected sandboxed folder after the picker scope ends | **Open issue #44.** Live root bookmark access needs to stay active for the watched lifetime | tracked blocker |
| A missing/stale bookmark silently falls back to whatever raw-path access the process happens to have | **Open issue #45.** Production app access should fail closed and request reauthorization | tracked blocker |

## Local image and text inference

Tier 1 uses Apple's on-device Vision framework for image labels, feature prints, and OCR. It does not require a downloaded model.

Tier 2 is optional. The repository currently contains:

- a Python-backed local CLIP/MiniLM path;
- a genuine Core ML MobileCLIP S0 provider;
- explicit provisioning/verification scripts;
- provider identity and preprocessing information stored with embedding provenance.

The normal app should continue to work when Tier 2 is absent. An unavailable requested provider must report unavailable rather than silently switching to a different embedding space.

## Media and transcription

Media containers are read through the broker's complete-snapshot boundary. Audio is decoded to PCM before it reaches the speech provider. The local Whisper adapter writes its own temporary input data; it is not given write authority over the source.

The core transcription path is implemented and tested with generated fixtures, but it is still opt-in and the app-level user setting is tracked in issue #47. Provider/model invalidation and failure/retry semantics are tracked in #42 and #43.

## Security-scoped folders

The app uses user-selected read-only security-scoped bookmarks for persistent folder authorization.

Manual indexing already resolves the saved bookmark while it indexes. The remaining live-index permission lifetime and fail-closed bookmark behavior are explicitly tracked in #44 and #45. Until those land, the sandboxed live-index path should be treated as alpha rather than a completed security guarantee.

## Verification

The normal verification stack includes:

```bash
swift test
bash scripts/e2e_local.sh
swift build -c release
scripts/package_app.sh .build/release
scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```

See `docs/VERIFICATION.md` for the detailed checks and current receipts.

## Still intentionally limited

- The project is pre-1.0 and does not claim a hardened stable release yet.
- Local model quality depends on the optional provider/model installed on the host.
- The real Whisper integration test is host-conditional because CI does not ship the local model/runtime.
- Search currently uses straightforward catalog scans for vectors rather than a dedicated ANN index at very large scale.
- Swift 6 concurrency cleanup in the app model is tracked in #46.

Security bugs should be reported through the private process described in the repository-root `SECURITY.md`, not through a public issue containing exploit details.
