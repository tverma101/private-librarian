# Security model

## The short version

Private Librarian may read files inside folders the user authorizes, but it must never modify those source files. All organization, search data, corrections, relationships, and learned rules live in a separate encrypted catalog.

The packaged app is designed to run without runtime network access. Optional
local model provisioning is an explicit setup step: `scripts/setup_models.sh`
installs a local runtime and pinned weights under Application Support rather
than allowing the app to silently download packages or model files.

## Hard boundaries

### Source files are read-only

`SourceBroker` is the source-access boundary. It opens regular files read-only, rejects symlink traversal, and checks file identity again after reads so a changed or replaced file is not silently accepted as the same generation.

The source subsystem must not gain APIs for writing or truncating files, moving/renaming/deleting files, Finder tags/xattrs, chmod/chown-style changes, or handing write-capable source handles to models/parsers.

### The catalog is the writable layer

The catalog is SQLCipher-encrypted and its key is stored in the app-owned
data-protection Keychain item in the app's default sandbox namespace. The
packager does not invent restricted Keychain-sharing entitlements without a
matching provisioning profile. Virtual categories, search text, embeddings, transcripts, similarity
relationships, review state, corrections, and learned rules belong in the
catalog. The CLI never opens this item and requires an explicit
`LIBRARIAN_CATALOG_KEY` for headless checks.

An item created by an older unsigned development CLI may require one explicit
macOS approval. Startup never probes that legacy item: the app renders first
and exposes **Migrate Existing Catalog**. That action preserves the key, copies
it once into the app-owned item, and caches a denial for the rest of the
process. It never rotates the key or deletes the old catalog to silence the
prompt.

Deleting or rebuilding the catalog must not alter originals.

### Models do not own filesystem authority

Image/text providers receive broker-owned bytes or derived text. Speech providers receive decoded PCM. Providers are not given source write authority.

### Runtime stays local

The packaged app is audited for sandbox entitlements and is expected to have no network client/server entitlement. The network-negative verification probe checks outbound, LAN, localhost, and listening attempts.

Provisioning scripts may use the network only when the user explicitly runs a download command. That is separate from normal app runtime.

## Current controls

| Threat | Current control | Verification |
|---|---|---|
| Source file changed by indexing | Read-only broker boundary; organization is catalog-only | immutability tests |
| Symlink escapes selected tree | no-follow enumeration/direct reads and `openat` walk | symlink escape tests |
| File swapped during read | opened-file + final-generation checks | TOCTOU tests |
| Malformed input crashes whole index | bounded per-file failure handling | resilience/OCR/media tests |
| Catalog readable as plain SQLite | vendored SQLCipher + encrypted-on-disk/wrong-key tests | CI + E2E |
| Prompt/document content becomes an action | content remains evidence/data; classification contract is validated | prompt-injection tests |
| Duplicate handling deletes originals | duplicate handling is virtual/report-only | behavior tests |
| Pending generation exposes old transcript as current | search filters to current indexed state | ASR/search regressions |
| Decoder receives truncated compressed container | complete bounded snapshot or fail closed | OCR/media snapshot tests |
| Model/helper receives source authority | image providers receive bytes/text; ASR receives PCM | Tier-2/media tests |
| Changed ASR provider/model is skipped | ASR processing identity includes provider/model generation and invalidates once | `ASRStateRegressionTests` |
| Temporary ASR failure is treated as success | explicit success / no-transcript / failure state; failures remain pending/retryable | `ASRStateRegressionTests` |
| Saved bookmark silently falls back to raw path | production app bookmark resolution fails closed and marks the source for reauthorization | app runtime/bookmark tests |
| Live indexing drops bookmark permission | live coordinator retains security-scoped leases for watched roots and releases them on restart/stop/remove | app/runtime tests + final packaged smoke |
| Old raw model labels become thousands of user-facing folders | bounded curated taxonomy + Smart Groups singleton suppression and per-lane caps | Smart Organization tests |

## Local inference

Tier 1 uses Apple's on-device Vision framework for image labels, feature prints, and OCR and requires no downloaded model.

Tier 2 is optional. The repository includes a Python-backed local CLIP/MiniLM baseline, a Core ML MobileCLIP S0 provider, and an explicit specialist registry for SigLIP2/DINOv3 plus opt-in OCR/VLM escalation. Provisioning resolves pinned Hub revisions, stages downloads before activation, verifies every regular file against a SHA-256 manifest, and places artifacts under Application Support by default. The worker is offline-only, receives broker-owned bytes or bounded derived text, and checks the manifest again before loading. Indexing and query-time search use the same selected embedding space; an unavailable provider fails closed instead of silently switching spaces. PaddleOCR-VL is skipped on macOS because its upstream runtime currently excludes macOS CPU/Apple silicon, so native Vision OCR remains the supported path.

## Media and transcription

Media containers cross the broker boundary as complete bounded snapshots. Audio is decoded to PCM before the speech provider sees it. Local Whisper is opt-in in the app and only activates when the configured executable/model passes preflight; the app does not silently download a model.

The processing identity includes the ASR provider/model generation. Provider failures remain retryable, retained older transcripts are hidden while the file is pending, successful retries replace the transcript, and a definitive no-transcript result may clear the old generation.

## Security-scoped folders

The app stores user-selected read-only security-scoped bookmarks. Missing, corrupt, or stale bookmark data fails closed and the source is marked as needing reauthorization.

For live indexing, the app resolves each active watched root before starting the coordinator and retains the resulting `SecurityScopedBookmarkLease` for the coordinator lifetime. Restarting, pausing, removing, or reauthorizing a root drops/replaces the old lease.

One OS-level validation remains before a daily-use release: run the packaged sandboxed app with a real folder selected through `NSOpenPanel`, quit/relaunch, then confirm a later FSEvent can still reopen and reindex the folder. Hosted CI cannot manufacture the genuine App Sandbox extension token created by that human picker flow. This final smoke is tracked in #44.

## Verification

The normal verification stack includes:

```bash
swift build
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
bash scripts/e2e_local.sh "$BUILD_DIR/librarian-cli"  # the fixture script creates a temporary key
scripts/package_app.sh --xcode --install
python3 scripts/audit_entitlements.py /Applications/PrivateLibrarian.app --expect-hardened
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```

See `docs/VERIFICATION.md` for the detailed checks and current receipts.

## Still intentionally limited

- The project is pre-1.0 and does not claim a hardened stable release yet.
- Local semantic quality depends on the optional provider/model installed on the host.
- The real Whisper integration test is host-conditional because hosted CI does not ship the local runtime/model.
- Search currently uses straightforward catalog scans for vectors rather than a dedicated ANN index at very large scale.
- The final packaged-app bookmark relaunch/FSEvent smoke in #44 is still required before calling the sandbox permission lifecycle fully proven.

Security bugs should be reported through the private process described in the repository-root `SECURITY.md`, not through a public issue containing exploit details.
