# Security model

## The short version

Private Librarian separates **analysis authority** from **explicit organization authority**.

- Indexing, OCR, embeddings, classification, search, and transcription open source files through a read-only broker boundary.
- The encrypted catalog is the normal writable state layer.
- Source files move only after the user reviews and confirms an **Apply to Finder** plan. That operation is contained to the user-authorized security-scoped root, journaled, and undoable.
- Normal indexing and inference are local/offline. The packaged app has outbound network-client permission solely so an explicit model-install action in Settings can download pinned packages/checkpoints. It has no network-server/listener entitlement.
- Hugging Face credentials entered in the app are stored in macOS Keychain and are passed into provisioning over stdin/in-memory rather than argv, shell history, UserDefaults, provenance manifests, or setup logs.

## Hard boundaries

### Analysis source access is read-only

`SourceBroker` is the analysis source-access boundary. It opens regular files read-only, rejects unsafe symlink traversal, and checks file identity again after reads so a changed or replaced file is not silently accepted as the same generation.

Models and parsers never receive a write-capable source handle. They receive broker-owned bytes, derived text, feature vectors, or decoded PCM.

Indexing code must not gain APIs for truncating, rewriting, renaming, deleting, tagging, chmod/chown-style changes, or arbitrary path-based mutation.

### Apply/Undo is the only source mutation boundary

The packaged app deliberately requests `com.apple.security.files.user-selected.read-write` because the product offers an explicit **Apply to Finder** operation. The entitlement does not make indexing writable by itself: analysis still goes through `SourceBroker` read-only APIs.

`OrganizationApplier` is the narrow mutation boundary. An Apply operation must:

1. originate from an explicit user-reviewed plan;
2. hold a valid active security-scoped bookmark lease for the selected root;
3. validate source and destination containment inside that authorized root;
4. move rather than silently duplicate/delete content;
5. journal every successful move in the encrypted catalog;
6. support Undo Last Apply;
7. fail closed when permission/bookmark state cannot be restored.

Code outside this boundary should not acquire generic filesystem write authority merely because the app entitlement is read/write.

### The catalog is the normal writable layer

The catalog is SQLCipher-encrypted and its key is stored in an app-owned generic-password Keychain item under a dedicated stable service name. Virtual categories, search text, embeddings, transcripts, similarity relationships, review state, corrections, learned rules, scan generations, access backoff, and Apply journals belong in the catalog.

The profile-free packager does not invent restricted data-protection or Keychain-sharing entitlements without a matching provisioning profile. The CLI never opens the app-owned catalog item and requires an explicit `LIBRARIAN_CATALOG_KEY` for headless checks.

An item created by an older unsigned development CLI may require one explicit macOS approval. Startup renders first and exposes **Migrate Existing Catalog**. That action preserves the key, copies it once into the new app-owned item, and never rotates the key or deletes the old catalog merely to silence a prompt.

Deleting or rebuilding the catalog must not alter originals.

### Models do not own filesystem authority

Image/text providers receive broker-owned bytes or derived text. Speech providers receive decoded PCM. Generative specialists operate behind canonical taxonomy/routing walls and are not given source paths with independent write authority.

A model result can recommend classification/review evidence; it cannot independently execute an Apply operation.

### Normal inference stays local

The packaged app has `com.apple.security.network.client` because the user can explicitly press **Install Selected Models**. It does **not** have `com.apple.security.network.server`.

That client entitlement must not be interpreted as permission for inference telemetry or cloud fallback. Production model workers force offline/local-file loading (`local_files_only` / offline Hub settings), and CI audits those settings separately from the entitlement audit.

Network-capable code belongs only in the explicit provisioning path and ordinary browser links opened through the system. No inbound/listening service is part of the application architecture.

### Model provisioning credentials

The app stores a user-supplied Hugging Face token as a generic-password Keychain item under a dedicated service/account.

For in-app provisioning:

1. Swift loads the token only after an explicit install action.
2. The token is written to the setup helper's stdin.
3. The setup helper forwards it to the specialist provisioner over stdin again.
4. Python passes the in-memory value directly to `huggingface_hub` API/download calls.
5. The token is never required in argv, shell history, UserDefaults, generated provenance files, or child-process environment variables.

Terminal users may still rely on normal Hugging Face CLI authentication or their own externally supplied environment. That does not change the stricter in-app credential path.

Gated repositories still require the account owner to accept/request upstream access. The provisioner preflights all checkpoints that actually need downloading before the first large transfer so a missing gated approval fails quickly.

## Security-scoped folders

The app stores user-selected **read/write security-scoped bookmarks** because Apply/Undo needs write authority inside the selected root. Bookmark restoration is still fail-closed.

For manual analysis, the app resolves the saved bookmark and retains its lease while the scoped scan is active. For live indexing, it resolves each active watched root before starting the coordinator and retains the resulting `SecurityScopedBookmarkLease` for the coordinator lifetime. Restarting, pausing, removing, or reauthorizing a root drops/replaces the old lease.

A bookmark created by an older build or one that macOS can no longer restore is shown as **Needs reauthorization**. The user can re-select that root through `NSOpenPanel`; the app must not fall back to scanning a raw path.

The presence of a read/write bookmark does not bypass the read-only analysis boundary: source extraction still goes through the broker, while writes remain isolated to explicit Apply/Undo.

## Large-library safety

The scale architecture is also a security/reliability boundary because unbounded memory growth or runaway background work can make a local organizer effectively unusable.

Current controls include:

- streaming/batched root discovery;
- disk-backed scan generations instead of a giant in-memory “seen paths” set;
- cooperative cancellation between files/stages and before missing reconciliation;
- bounded inaccessible-prefix state plus persisted retry backoff;
- incomplete/cancelled scans never performing destructive missing-file reconciliation;
- SQL-side bounded UI pages;
- batched vector scoring with only top-K candidates retained in memory;
- bounded semantic chunk fan-out;
- specialist model serialization/unloading under the target-Mac execution ceiling.

## Current controls

| Threat | Current control | Verification |
|---|---|---|
| Indexing changes a source file | `SourceBroker` opens analysis inputs read-only | immutability tests |
| Apply moves an unintended file | explicit plan + active bookmark lease + root containment + journal | Apply/Undo regression tests |
| Apply cannot be reversed | catalog move journal + Undo Last Apply | Apply/Undo regression tests |
| Symlink escapes selected tree | no-follow enumeration/direct reads and guarded containment | symlink escape tests |
| File swapped during read | opened-file + final-generation checks | TOCTOU tests |
| Malformed input crashes whole index | bounded per-file failure handling | resilience/OCR/media tests |
| Catalog readable as plain SQLite | vendored SQLCipher + encrypted-on-disk/wrong-key tests | CI + E2E |
| Prompt/document content becomes an action | content remains evidence; model result cannot execute filesystem mutation | prompt-injection tests |
| Duplicate handling deletes originals | duplicate handling is virtual/report-only | behavior tests |
| Pending generation exposes stale transcript | search filters to current indexed state | ASR/search regressions |
| Decoder receives truncated compressed container | complete bounded snapshot or fail closed | OCR/media snapshot tests |
| Model/helper receives source write authority | providers receive bytes/text/PCM only | Tier-2/media tests |
| Saved bookmark silently falls back to raw path | restoration fails closed and marks source for reauthorization | runtime/bookmark tests |
| Live indexing loses sandbox permission | live coordinator retains security-scoped leases | runtime tests + host smoke |
| Old raw labels create thousands of folders | curated taxonomy + singleton suppression/per-lane caps | Smart Organization tests |
| Huge source tree exhausts memory | batched traversal/SQL paging/top-K vector scoring | scale regressions |
| Pause/remove leaves runaway scan | cooperative cancellation token and safe boundaries | cancellation regressions |
| Gated model failure wastes huge download | all needed Hub revisions preflight before transfer | provisioning contract/host smoke |
| App-supplied HF token leaks through argv/env | Keychain → stdin → in-memory Hub calls | CI auth contract + secret scan |
| Inference silently calls network | local-files-only/offline worker settings | CI model-runtime contract |
| App opens inbound network service | no network-server entitlement | entitlement audit |

## Local inference

Tier 1 uses Apple's on-device Vision framework for image labels, feature prints, and OCR and requires no downloaded model.

Tier 2 is optional. The repository includes local embedding paths and a specialist registry for SigLIP2/DINOv3 plus opt-in VLM escalation. Provisioning resolves pinned Hub revisions, preflights required access, stages downloads before activation, verifies every regular file against a SHA-256 manifest, and places artifacts under the app's Foundation-resolved Application Support directory.

The current fp16 specialist set is constrained by an explicit target-Mac memory ceiling. Larger models are not exposed merely because they exist upstream; they require a separately validated quantized/MLX runtime before entering production routing.

PaddleOCR-VL remains unsupported on the current macOS target path, so native Vision OCR is the supported document-OCR baseline.

### Bootstrap-runtime limitation

The default package does not yet bundle a Python distribution. In-app model setup therefore requires a usable bootstrap Python on the host to create the isolated model runtime, unless the release was intentionally packaged with a compatible runtime. This is a distribution limitation, not a security reason to silently execute arbitrary downloads or unpinned bootstrap code.

A future self-contained bootstrap must have explicit provenance/version pinning and release verification before this document claims clean-Mac model provisioning is self-contained.

## Media and transcription

Media containers cross the broker boundary as complete bounded snapshots. Audio is decoded to PCM before the speech provider sees it. Local Whisper is opt-in and only activates when the configured executable/model passes preflight; the app does not silently fetch a transcription model.

The processing identity includes the ASR provider/model generation. Provider failures remain retryable, retained older transcripts are hidden while the file is pending, successful retries replace the transcript, and a definitive no-transcript result may clear the old generation.

## Verification

The normal verification stack includes:

```bash
swift build
swift build -Xswiftc -swift-version -Xswiftc 6 -Xswiftc -warnings-as-errors
swift test
swift build -c release
BUILD_DIR="$(swift build -c release --show-bin-path)"
bash scripts/e2e_local.sh "$BUILD_DIR/librarian-cli"
scripts/package_app.sh --xcode --no-dmg
python3 scripts/audit_entitlements.py .build/package-stage/PrivateLibrarian.app --expect-hardened
```

CI separately asserts:

- `user-selected.read-write` + app-scope bookmarks are present;
- outbound `network.client` is present for explicit provisioning;
- inbound `network.server` is absent;
- production inference code remains offline/local-files-only;
- the in-app HF credential path is stdin/in-memory and token-like secrets are not tracked;
- the current specialist router obeys its memory ceiling;
- normal source analysis stays read-only and Apply/Undo remains the narrow mutation path.

A blanket “deny all networking and expect every request to fail” probe is no longer an accurate packaged-app test because explicit provisioning intentionally needs outbound client access. The security property is **no unintended runtime network use**, not absence of the client entitlement.

See `docs/VERIFICATION.md` for detailed checks and current receipts.

## Remaining host/account validation

Hosted CI cannot manufacture the genuine App Sandbox extension token created when a human selects a folder through `NSOpenPanel`. It also cannot use the owner's private Hugging Face account approval.

Before a daily-use release, perform one packaged smoke that:

1. selects a real folder;
2. indexes it without mutation;
3. performs one reviewed Apply and Undo;
4. quits/relaunches and restores the bookmark;
5. confirms a later FSEvent reindexes a changed file;
6. pauses/removes/reauthorizes the root and confirms leases are released/replaced;
7. saves an approved Hugging Face token and provisions the gated DINOv3 checkpoint through Settings.

These are genuine OS/account acceptance boundaries and should not be replaced by synthetic CI claims.

## Still intentionally limited

- The project is pre-1.0 and does not claim a hardened stable release yet.
- Local semantic quality depends on the optional provider/model installed on the host.
- The real Whisper integration test is host-conditional because hosted CI does not ship the local runtime/model.
- The default release does not yet ship a self-contained Python bootstrap for model provisioning.
- The final packaged-app bookmark Apply/Undo/relaunch/FSEvent smoke remains host-only.
- A real gated-model provisioning smoke requires an account that has actually been granted upstream access.

Security bugs should be reported through the private process described in the repository-root `SECURITY.md`, not through a public issue containing exploit details.
