# Architecture

Private Librarian is a native macOS app plus reusable core library that builds a searchable, encrypted catalog of user-selected local folders. Its architecture deliberately separates **read-only analysis** from the one explicit, reviewed source-mutation workflow: **Apply to Finder / Undo**.

> Indexing, OCR, classification, embeddings, search, and transcription never receive write-capable source handles. Real Finder moves happen only through `OrganizationApplier`, after user confirmation, inside a valid read/write security-scoped root, with a catalog journal for Undo.

If you want a quick tour rather than a design reference, start with the [project map](PROJECT_MAP.md).

## Invariant stack

```text
macOS App Sandbox
  ├─ user-selected read/write security-scoped roots
  │    ├─ analysis uses SourceBroker read-only APIs
  │    └─ explicit Apply/Undo uses OrganizationApplier only
  ├─ app-scoped bookmark persistence
  └─ outbound network client only for explicit model provisioning
       (no network-server entitlement)
        +
SourceBroker
  O_RDONLY / no-follow / containment / TOCTOU checks
        +
classifier + model output contracts
  derived evidence cannot directly become a filesystem action
        +
SQLCipher encrypted catalog
  writable knowledge, scan state, review state, move journal
        +
virtual organization by default
  Finder changes require an explicit reviewed Apply plan
```

This distinction matters: the app **has** read/write sandbox authority for roots the user selects because Apply/Undo is a product feature, but the analysis subsystem remains technically read-only.

## Target/module map

```text
SQLCipher
    ↓
LibrarianCore
    ↓
LibrarianAppSupport ─────┐
                         ├─ LibrarianApp
LibrarianCore ───────────┘
    ↓
 librarian-cli

LibrarianCore + LibrarianAppSupport → LibrarianTests
```

| Module / component | Responsibility |
|---|---|
| `SourceBroker` | Analysis source-access boundary. Opens regular files read-only, rejects unsafe symlink traversal, verifies identity around reads, and provides bounded/complete broker-owned snapshots to downstream code. It exposes no general source-write API. |
| `SourceBroker+StreamingEnumeration` | Deterministic bounded-memory traversal for large trees, including early max-file stop, unreadable-directory reporting, and external sorting for huge sibling sets. |
| `SafeReader` semantics | Every analysis read goes through the broker's no-follow fd. A path swapped for a symlink between stat/open fails rather than leaking or following it. |
| `FileIdentity` / `FileID` | lstat-level identity and stable catalog IDs used for incremental processing and TOCTOU checks. |
| `EvidenceExtractor` | Bounded UTF-8/magic/cloud-placeholder evidence. |
| `PDFText` / `OfficeContainer` | Decode only broker-owned complete snapshots within explicit caps; malformed inputs fail closed. |
| `ScreenshotIntelligence` | Explainable screenshot evidence from dimensions, OCR, filename hints, and optional Vision/model signals; uncertain cases can enter Review. |
| `VisionOCR` / `VisionImageAnalyzer` | Apple on-device OCR/image feature paths receiving bytes, not write-capable source handles. |
| `BrokerPCMDecoder` / `WhisperCLITranscriptionProvider` | Broker snapshot → local decode/PCM → optional local ASR. No cloud fallback is part of the normal runtime. |
| `RuleBasedClassifier` + `ClassifierContract` | Deterministic baseline classification and strict canonical output wall. Model/document content cannot call filesystem actions. |
| `LearnedRuleEngine` | Evidence-bound, reversible learned corrections in catalog state. |
| `Scheduler` | Coordinates expensive stages so indexing does not starve interactive work. |
| `Catalog` | SQLCipher/FTS5 authority for files, text, categories, screenshots, hashes, errors, learned rules, similarity, scan generations, access backoff, project summaries, and Apply journals. |
| `CatalogKeychain` | Stable app-owned generic-password Keychain service for the catalog key. |
| `EmbeddingProvider` | Provider-neutral image/text embedding contract. Unavailable providers fail closed rather than silently switching vector spaces. |
| `LocalModelRouter` / `SpecialistModelBridge` | Cheap-first specialist routing. SigLIP2 uses semantic image/text space. Native Vision remains the zero-download visual baseline. Optional DINOv3 uses a separate visual space only when explicitly provisioned. VLMs are transient and unloaded according to the target-Mac memory contract. Production inference uses local/offline loading. |
| `HuggingFaceTokenStore` | Optional advanced Keychain service for a user-supplied credential used by explicitly selected gated models. Normal Fast/Balanced/Quality setup does not depend on it. |
| `AppModelSetup` | Explicit user-triggered model provisioning from the Analyze flow or Settings. Resolves the packaged setup helper and Foundation Application Support paths, captures bounded logs, and never runs as an indexing side effect. Normal profiles pass no credential. |
| `OrganizationGraphBuilder` | Builds virtual relationships/groups in the encrypted catalog. It never mutates Finder. |
| `ReviewInbox` | Low-confidence review and catalog-only corrections. |
| `Indexer` | Per-file processing authority: identity → extraction → classification/providers → commit. Changed-during-index generations are discarded. |
| `ScalableIndexSession` | Large-root orchestration: bounded discovery batches, disk-backed scan generations, cancellation, access backoff, safe missing reconciliation, and one aggregate similarity refresh. |
| `DuplicateDetector` | Report-only exact duplicate pipeline. It never deletes originals. |
| `SimilarityClustering` | Derived exact/feature/embedding relationships persisted in catalog; relations remain signal-space explicit. |
| `SearchService` | FTS5 plus optional semantic/visual search. Vector rows are scored in fixed batches while only top-K candidates stay in Swift memory. |
| `LiveIndexCoordinator` | FSEvents reconciliation for authorized roots. The app owns active security-scoped leases for watched roots and releases/replaces them on pause/remove/reauthorize/restart. |
| `OrganizationApplier` | **Only deliberate Finder mutation boundary.** Validates a reviewed move plan against an active security-scoped root, performs journaled moves, and supports Undo Last Apply. Models/classifiers do not call it directly. |
| `LibrarianModel` | Main-actor app coordinator for bookmarks, indexing sessions, live leases, settings, model setup status, review/apply UI state, and shutdown. |
| `LibrarianApp` | SwiftUI product shell. The packaged app is sandboxed with user-selected read/write + app bookmarks + outbound network client for explicit provisioning. |
| `librarian-cli` | Headless development/verification harness. It is intentionally not shipped in the production app bundle. |

## Source authorization lifecycle

### Folder selection

`NSOpenPanel` gives the app a user-selected security-scoped URL. The app persists bookmark data with security scope. Because the user-facing product can perform Apply/Undo, the packaged entitlement is read/write rather than read-only.

### Manual analysis

The app resolves the saved bookmark, starts security-scoped access, and holds a `SecurityScopedBookmarkLease` for the analysis lifetime. The `Indexer` still opens files through `SourceBroker` read-only methods.

### Live indexing

`LibrarianModel` resolves active watched roots before starting `LiveIndexCoordinator` and retains those leases while the coordinator is alive. Pause/remove/restart/reauthorize drops or replaces the corresponding lease.

If restoration fails or a root becomes unavailable, the app marks it as needing reauthorization and does **not** silently continue through a raw path.

### Apply to Finder

The user reviews a move plan in the app. Only then does `OrganizationApplier` use the already-authorized read/write scope to move files inside that root. Every move is journaled for Undo. This boundary is intentionally outside `LibrarianCore`'s read-only analysis APIs.

## Model provisioning and runtime networking

Normal model inference is local/offline. The packaged app nevertheless needs outbound `network.client` permission because **Set Up & Analyze** and explicit Settings setup may download a pinned runtime and pinned model snapshots.

### Consumer provisioning flow

The product profiles are account-free by contract:

```text
Choose Balanced / Quality
  ↓
Set Up & Analyze
  ↓
AppModelSetup → setup_models.sh
  ↓
app-private pinned Python runtime (when needed)
  ↓
provision_specialist_models.py
  ↓
public profile checkpoints only
  ↓
pinned staged snapshots + SHA-256 provenance
  ↓
refresh readiness → resume requested analysis
```

`embeddings`, `balanced`, and `quality` explicitly exclude registry entries marked `gated`. Therefore a normal quality choice cannot turn into an external account/token/license-approval workflow.

On Apple-silicon macOS, `setup_models.sh` can bootstrap its own app-private CPython runtime when no compatible runtime exists. It uses one dated `python-build-standalone` asset, verifies the repository-pinned SHA-256 before extraction/use, and keeps the runtime under Private Librarian's Application Support tree. Homebrew, Xcode, and a global Python are not consumer prerequisites.

### Optional gated specialist flow

DINOv3 remains a supported optional advanced visual-similarity specialist. If a user deliberately provisions it, the credential flow is separate from the normal profiles:

```text
explicit optional DINOv3 install
  ↓
HuggingFaceTokenStore / operator credential
  ↓ stdin
setup_models.sh / provision_specialist_models.py
  ↓ token passed only in memory
huggingface_hub
  ↓
pinned DINOv3 snapshot + SHA-256 provenance
```

The router uses DINOv3 opportunistically when available. Its absence never blocks Fast, Balanced, Quality, or Analyze.

Important constraints:

- no network-server/listener entitlement;
- no inference telemetry/cloud fallback implied by client permission;
- normal workers force local/offline model loading;
- consumer profile selection contains no gated checkpoints;
- an optional gated model is preflighted before its large transfer;
- an app-supplied optional token does not enter argv, shell history, UserDefaults, child environment variables, or model manifests;
- model snapshots are pinned to immutable revisions and verified before activation;
- the clean-Mac Python bootstrap is pinned and checksum-verified before execution;
- specialist workers are serialized/unloaded under the current target-Mac memory ceiling.

## Large-tree indexing

`ScalableIndexSession` wraps the per-file `Indexer` so browser-sized trees do not require memory proportional to total file count.

The root flow is:

```text
security-scoped root lease
    ↓
streaming/batched discovery
    ↓
per-file incremental Indexer work
    ↓
catalog scan-generation markers
    ↓
only after a complete uncancelled scan:
missing-file reconciliation
    ↓
one similarity refresh + project summary refresh
```

Safety properties:

- discovery batches are bounded;
- huge direct-child sets can use a disk-backed sort path;
- cancellation is checked between files/stages, never by tearing an atomic catalog commit;
- cancelled/limited/unavailable scans do not claim filesystem absence;
- inaccessible prefixes have bounded in-memory tracking and catalog backoff;
- a manual retry/reauthorization can clear relevant backoff;
- similarity is rebuilt once per scan rather than once per batch.

## Search memory shape

Exact FTS/search filters remain catalog queries. Semantic and visual vector scoring read vector rows in fixed SQL batches and retain only top-K candidates in memory. SigLIP semantic space, optional DINO structural space, and native Vision feature evidence remain distinct; vectors from different model spaces are never compared as if interchangeable.

## Path spelling contract

Enumeration reports paths using the caller-selected root spelling while disk operations may use the real URL internally. This prevents one scan from mixing aliases such as `/var/...` and `/private/var/...` and then incorrectly treating one spelling as missing.

## Missing-file semantics

A previously indexed file is marked `missing` only after a complete eligible scan can establish absence. Cancelled, explicitly limited, inaccessible, excluded, or permission-lost regions do not trigger destructive missing reconciliation. Missing catalog state never deletes or reconstructs the source file.

## Similarity semantics

Similarity is derivative catalog state. Exact hashes and visual feature spaces produce near-duplicate/structural relations; semantic embedding spaces produce semantic relations. Stable IDs and reasons are persisted so one signal does not get mislabeled as another. A missing node loses derived membership/edges but is not deleted from the user's filesystem.

## Fixture honesty

Security fixtures must make containment failures directly observable. For example, symlink-breakout fixtures place protected data outside the selected root and create only an in-root symlink pointing outward. A protected file appearing in catalog results then represents a real boundary failure rather than an ambiguous fixture.

## Acceptance boundaries

Hosted CI can verify code paths, package entitlements, synthetic bookmark failure handling, source immutability, Apply containment, public-profile selection, optional auth plumbing, the pinned bootstrap contract, and offline-worker settings.

It cannot manufacture or economically repeat on every commit:

- a genuine `NSOpenPanel` App Sandbox extension token and prove it after a real quit/relaunch;
- a complete multi-gigabyte public model setup inside a pristine packaged consumer sandbox;
- a private upstream approval for an optional gated DINOv3 install.

Before a daily-use release, the host smoke therefore needs a clean Apple-silicon account, Fast analysis, account-free Balanced setup with automatic resume, Apply/Undo, bookmark restoration after relaunch, FSEvent refresh, and pause/remove/reauthorization. The optional DINOv3 account smoke is separate and is not a daily-use blocker.
