# Security model

## The short version

Private Librarian separates **analysis authority** from **explicit organization authority**.

- Indexing, OCR, embeddings, classification, search, and transcription open source files through a read-only broker boundary.
- The encrypted catalog is the normal writable state layer.
- Source files move only after the user reviews and confirms an **Apply to Finder** plan. That operation is contained to the user-authorized security-scoped root, journaled, and undoable.
- Normal indexing and inference are local/offline. The packaged app has outbound network-client permission only for explicit model setup and ordinary browser links. It has no network-server/listener entitlement.
- Normal Fast/Balanced/Quality setup provisions public checkpoints only and requires no external account/token.
- Credentials for an explicitly selected optional gated model are stored in macOS Keychain and travel through provisioning over stdin/in-memory rather than argv, shell history, UserDefaults, provenance manifests, or setup logs.

## Hard boundaries

### Analysis source access is read-only

`SourceBroker` is the analysis source-access boundary. It opens regular files read-only, rejects unsafe symlink traversal, and checks file identity around reads so a changed/replaced file is not silently accepted as the same generation.

Models and parsers receive broker-owned bytes, derived text, feature vectors, or decoded PCM. They do not receive generic write-capable source handles.

### Apply/Undo is the only source mutation boundary

The packaged app deliberately requests `com.apple.security.files.user-selected.read-write` because the product offers explicit **Apply to Finder** and Undo. That entitlement does not make indexing writable: analysis still goes through `SourceBroker` read-only APIs.

`OrganizationApplier` is the narrow mutation boundary. An Apply operation must:

1. originate from an explicit user-reviewed plan;
2. hold a valid active security-scoped bookmark lease for the selected root;
3. validate source and destination containment inside that authorized root;
4. move rather than silently duplicate/delete content;
5. journal every successful move in the encrypted catalog;
6. support Undo Last Apply;
7. fail closed when permission/bookmark state cannot be restored.

Code outside this boundary should not acquire generic filesystem write authority merely because the app entitlement is read/write.

### Catalog and Keychain

The catalog is SQLCipher-encrypted. Its key is stored in an app-owned generic-password Keychain item under a stable service name. Virtual categories, extracted text, embeddings, transcripts, similarity relationships, review state, corrections, learned rules, scan generations, access backoff, and Apply journals belong in the catalog.

Optional gated-model credentials use a separate generic-password Keychain service/account. The consumer setup path does not need that credential. Deleting or rebuilding catalog state must not alter originals.

### Normal inference stays local

The app has `com.apple.security.network.client` because the user can explicitly start model setup. It does **not** have `com.apple.security.network.server`.

Production model workers force offline/local-file loading (`local_files_only` / offline Hub settings). There is no cloud inference fallback. Network-capable code belongs only to explicit provisioning and system-browser links.

### Consumer model profiles are public-only

`embeddings`, `balanced`, and `quality` are the one-click product profiles. Their provisioner selection explicitly rejects any registry entry marked `gated`. This is a product/security contract: selecting a normal quality mode must not unexpectedly create an account, credential, license-approval, or secret-management dependency.

DINOv3 remains registered as an optional gated visual-similarity specialist. If it is explicitly installed, the router may use its separate visual embedding space. Its absence never blocks Fast, Balanced, Quality, or Analyze.

### Optional gated-model credentials

For an explicitly requested gated-model install:

1. Swift/Terminal supplies a token only after the user deliberately chooses that advanced path.
2. The token is written to the setup helper's stdin.
3. The helper forwards it to the specialist provisioner over stdin.
4. Python passes the in-memory value directly to `huggingface_hub` API/download calls.
5. The token is not required in argv, shell history, UserDefaults, generated provenance files, or child-process environment variables.

Gated repositories still require the account owner to accept/request upstream access. An explicit gated-model install preflights its revision/access before its large transfer. That failure is isolated from the normal public profile installation.

## Pinned clean-Mac runtime bootstrap

A clean Apple-silicon Mac does not need Homebrew, Xcode, or a preinstalled global Python for the optional local-model setup path. When the app-private runtime is absent and no compatible host Python is available, `setup_models.sh` downloads one exact `python-build-standalone` archive into Private Librarian's Application Support directory.

Because this is executable supply-chain code, the bootstrap is intentionally narrow:

- CPython `3.11.16`;
- dated upstream release `20260825`, never `latest`;
- Apple-silicon `install_only` archive;
- repository-pinned SHA-256 `2e50ed6ec49d8714a83c093e9ce74e1b8b21a2c64a49c3b603471d9c4caac76b`;
- `/usr/bin/curl` restricted to HTTPS/TLS and downloading to a file, never piped into a shell;
- `/usr/bin/shasum -a 256` must match before extraction/use;
- checksum mismatch fails closed;
- extracted runtime stays in the app's private Application Support tree.

CI asserts the exact version, dated release, digest, checksum-verification command, HTTPS restriction, absence of a `latest` URL, and absence of curl-pipe-shell patterns. Normal inference then uses the resulting runtime offline.

Automatic bootstrap currently targets Apple-silicon macOS. Intel hosts must provide a compatible Python 3.10+ via `LIBRARIAN_BOOTSTRAP_PYTHON` or use a package that already contains a compatible runtime.

A green CI contract is not the same as a completed consumer install: the final packaged sandbox still needs a clean-user-account smoke that downloads/executes the pinned runtime and provisions a real public model profile under the final distribution signature.

## Security-scoped folders

The app stores user-selected **read/write security-scoped bookmarks** because Apply/Undo needs write authority inside the selected root. Bookmark restoration is fail-closed.

For manual analysis, the app resolves the saved bookmark and retains its lease while the scoped scan is active. Live indexing resolves each active watched root before starting and retains each `SecurityScopedBookmarkLease` for the coordinator lifetime. Restarting, pausing, removing, or reauthorizing a root drops/replaces the old lease.

A bookmark that macOS can no longer restore is shown as **Needs reauthorization**. The user re-selects that root through `NSOpenPanel`; the app must not silently fall back to a raw path.

The presence of a read/write bookmark does not bypass the read-only analysis boundary: source extraction still goes through the broker, while writes remain isolated to explicit Apply/Undo.

## Large-library safety

Scale controls are also reliability/security controls. Current safeguards include:

- streaming/batched root discovery;
- disk-backed scan generations instead of a giant in-memory seen-path set;
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
| Apply moves an unintended file | reviewed plan + active bookmark lease + containment + journal | Apply/Undo regressions |
| Apply cannot be reversed | catalog move journal + Undo Last Apply | Apply/Undo regressions |
| Symlink escapes selected tree | no-follow enumeration/direct reads + containment | symlink tests |
| File swapped during read | opened-file/final-generation checks | TOCTOU tests |
| Malformed input crashes whole index | bounded per-file failure handling | resilience/OCR/media tests |
| Catalog readable as plain SQLite | vendored SQLCipher + encrypted-on-disk/wrong-key tests | CI + E2E |
| Prompt/document content becomes an action | content remains evidence; models cannot execute Apply | prompt-injection tests |
| Duplicate handling deletes originals | virtual/report-only duplicate handling | behavior tests |
| Model/helper gets source write authority | providers receive bytes/text/PCM only | Tier-2/media tests |
| Saved bookmark falls back to raw path | restoration fails closed + reauthorization UI | runtime/bookmark tests |
| Live indexing loses sandbox permission | live coordinator retains bookmark leases | runtime tests + host smoke |
| Huge source tree exhausts memory | batched traversal/SQL paging/top-K scoring | scale regressions |
| Normal quality mode unexpectedly needs an account | consumer profile selection excludes every gated registry entry | specialist contract test |
| Explicit gated failure wastes unrelated public downloads | gated model is installed separately and preflighted first | provisioning contract/optional host smoke |
| Optional app token leaks through argv/env | Keychain → stdin → in-memory Hub calls | CI auth contract + secret scan |
| Runtime bootstrap executes unverified code | pinned dated asset + SHA-256-before-exec + no curl pipe | CI bootstrap contract + host smoke |
| Inference silently calls network | local-files-only/offline worker settings | CI model-runtime contract |
| App opens inbound network service | no network-server entitlement | entitlement audit |

## Local inference

Tier 1 uses Apple's on-device Vision framework and requires no downloaded model.

Tier 2 is optional. Consumer provisioning resolves pinned **public** Hub revisions, stages downloads before activation, verifies model files against SHA-256 provenance manifests, and places artifacts under the app's Foundation-resolved Application Support directory. Optional gated specialists use the same provenance and offline-runtime rules when explicitly installed.

The current fp16 specialist set is constrained by an explicit target-Mac memory ceiling. Larger models require a separately validated quantized/MLX runtime before entering production routing. PaddleOCR-VL remains unsupported on the current macOS path, so native Vision OCR is the document-OCR baseline.

## Media and transcription

Media containers cross the broker boundary as complete bounded snapshots. Audio is decoded to PCM before the speech provider sees it. Local Whisper is opt-in and only activates when the configured executable/model passes preflight; it is not silently downloaded by normal analysis.

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
- production inference stays offline/local-files-only;
- normal model profiles contain no gated registry entries;
- optional gated credentials use the stdin/in-memory path and token-like secrets are not tracked;
- the clean-Mac runtime bootstrap is pinned and cannot regress to `latest` or curl-pipe-shell;
- the specialist router obeys its memory ceiling;
- normal source analysis stays read-only and Apply/Undo remains the narrow mutation path.

## Remaining host validation

Hosted CI cannot manufacture the genuine App Sandbox extension token created when a human selects a folder through `NSOpenPanel`, and it cannot economically perform the full external runtime/dependency/model bootstrap inside a clean consumer sandbox on every commit.

Before a daily-use release, perform one packaged smoke that:

1. launches on a clean Apple-silicon user account without Homebrew/global Python or a model-hosting account;
2. selects a real folder;
3. indexes it without mutation;
4. switches to Balanced, provisions the pinned public runtime/model stack through the in-app flow, and confirms analysis resumes;
5. performs one reviewed Apply and Undo;
6. quits/relaunches and restores the bookmark;
7. confirms a later FSEvent reindexes a changed file;
8. pauses/removes/reauthorizes the root and confirms leases are released/replaced.

A separate private-account smoke is required only if the optional DINOv3 advanced path is going to be advertised as supported. It is not a consumer/daily-use blocker.

These are genuine OS/distribution acceptance boundaries and should not be replaced by synthetic CI claims.

## Still intentionally limited

- The project is pre-1.0 and does not claim a hardened stable release yet.
- Local semantic quality depends on the optional provider/model installed on the host.
- The real Whisper integration test is host-conditional because hosted CI does not ship that local runtime/model.
- Automatic clean-Mac Python bootstrap currently targets Apple-silicon macOS; Intel requires a supplied compatible runtime.
- The final packaged-app bookmark Apply/Undo/relaunch/FSEvent smoke remains host-only.
- A full clean-account packaged public-model bootstrap smoke remains host-only because of its download/runtime cost.
- Optional DINOv3 provisioning remains a separate account-gated advanced path.

Security bugs should be reported through the private process described in the repository-root `SECURITY.md`, not through a public issue containing exploit details.
