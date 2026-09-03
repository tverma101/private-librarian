# Project map

Private Librarian is a macOS app for making a searchable index of folders you
choose. It keeps the original files in place. Most organization happens in an
encrypted local catalog, not in Finder.

This page is the short tour of the repository. Use it when you do not know where
to start. The detailed rules live in the linked architecture and security docs.

## The product flow

```text
Choose folders
    ↓
SourceBroker reads them safely
    ↓
Indexer extracts text and media evidence
    ↓
Classifiers and optional local models add labels and relationships
    ↓
Catalog stores the encrypted index
    ↓
App searches and displays virtual groups
    ↓
You explicitly approve an Apply to Finder plan, if you want real moves
```

Here is what each step means:

1. **Choose folders.** The app asks macOS for access to folders you select. It
   saves a security-scoped bookmark so it can request that access again later.
2. **Read safely.** `SourceBroker` is the only part of the code that opens source
   files. It uses read-only, no-follow file access and refuses unsafe paths.
3. **Index.** `Indexer` walks the folders, skips unchanged files, and sends
   broker-owned bytes or derived data to extractors and classifiers.
4. **Analyze.** Built-in rules handle the baseline classification. OCR, image
   analysis, duplicate checks, embeddings, and transcription are separate
   stages; optional local models are opt-in.
5. **Store.** `Catalog` writes the knowledge produced by indexing to SQLCipher,
   an encrypted SQLite database. The catalog is the writable data layer.
6. **Explore.** The app searches the catalog and presents Smart Groups,
   screenshots, projects, duplicates, similarity families, review items, and
   missing files as views of the index.
7. **Apply only when asked.** `LibrarianAppSupport` creates an explicit,
   journaled move plan. Finder moves files only after you confirm it, and the
   last apply can be undone.

The important safety rule is: **source files are read-only by default; the
catalog is where Private Librarian writes.** See [Security](SECURITY.md) for the
full boundary and threat model.

## What builds in this package?

`Package.swift` defines the targets and their dependency direction:

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

| Target | What it is for | Start here |
| --- | --- | --- |
| `SQLCipher` | Vendored C target that provides encrypted SQLite and FTS5. | `ThirdParty/sqlcipher/` |
| `LibrarianCore` | The reusable engine: source access, indexing, catalog access, analysis, search, and virtual organization. | `Sources/LibrarianCore/` (organized by feature folders) |
| `LibrarianAppSupport` | App-only services such as bookmark configuration and the explicit Finder-apply workflow. | `Sources/LibrarianAppSupport/` |
| `LibrarianApp` | The native SwiftUI app, its screens, its app model, and lifecycle. | `Sources/LibrarianApp/` |
| `librarian-cli` | A headless development and verification tool. It does not ship inside the packaged app. | `Sources/librarian-cli/main.swift` |
| `LibrarianTests` | The XCTest suite for safety, behavior, resilience, scale, and integration boundaries. | `Tests/LibrarianTests/` |

The app depends on the core library. The core library does not depend on the
app. That separation lets the CLI and tests exercise the indexing engine
without launching the GUI.

## How the source folders are named

The folder names describe the job of the code inside them:

```text
Sources/LibrarianCore/
├── SourceAccess/       safely reads the folders you choose
├── Catalog/            stores the encrypted index
├── Indexing/           walks files and coordinates processing
├── ContentAnalysis/    extracts and classifies file evidence
├── LocalModels/        runs optional local model providers
├── Search/             finds text, semantic, and similarity matches
└── Organization/       builds virtual groups and review relationships

Sources/LibrarianAppSupport/
├── Runtime/            supplies app configuration
└── FileOrganization/   performs confirmed Finder moves and undo

Sources/LibrarianApp/
├── App/                owns app setup and settings
└── Library/            owns the main library screens
```

These are folders inside the existing targets, not new Swift modules. If you
need a behavior, begin with its folder; if you need a dependency boundary,
begin with the target table above.

## Where to look for a feature

Start with the row that matches the behavior you are changing. Read the named
file, then follow its collaborators rather than searching the whole repository
at random.

| If you are changing… | Look here first | What that area owns |
| --- | --- | --- |
| Folder access, symlinks, or source-file safety | `Sources/LibrarianCore/SourceAccess/SourceBroker.swift` | Read-only file access, safe enumeration, and containment checks |
| File identity and changed-file detection | `Sources/LibrarianCore/SourceAccess/FileIdentity.swift`, `Sources/LibrarianCore/SourceAccess/FileID.swift`, `Sources/LibrarianCore/Indexing/ChangeDetection.swift` | Stable IDs and the decision to skip or reprocess a file |
| The indexing pipeline | `Sources/LibrarianCore/Indexing/Indexer.swift` | Enumeration, extraction, classification, commit, and incremental work |
| Encrypted storage or schema changes | `Sources/LibrarianCore/Catalog/Catalog.swift` and the other files in `Sources/LibrarianCore/Catalog/` | SQLCipher setup, migrations, queries, and catalog transactions |
| Plain-text or document extraction | `Sources/LibrarianCore/ContentAnalysis/EvidenceExtractor.swift`, `PDFText.swift`, `OfficeContainer.swift` | Bounded evidence from text, PDFs, and office containers |
| Rules and categories | `Sources/LibrarianCore/ContentAnalysis/RuleBasedClassifier.swift`, `ClassifierContract.swift`, `Sources/LibrarianCore/Organization/SmartOrganization.swift` | Safe classification output and bounded Smart Groups |
| Screenshots and OCR | `Sources/LibrarianCore/ContentAnalysis/ScreenshotIntelligence.swift`, `VisionOCR.swift`, `VisionImageAnalyzer.swift` | Image evidence, screenshot subtypes, and on-device text recognition |
| Audio or video transcripts | `Sources/LibrarianCore/ContentAnalysis/MediaDecoder.swift`, `MediaIntelligence.swift`, `Sources/LibrarianCore/LocalModels/TranscriptionState.swift` | Broker-owned media decoding and optional local transcription |
| Embeddings and local specialist models | `Sources/LibrarianCore/LocalModels/EmbeddingProvider.swift`, `LocalModelRouter.swift`, `SpecialistModelBridge.swift` | Optional offline model providers and their readiness checks |
| Exact duplicates or similarity families | `Sources/LibrarianCore/ContentAnalysis/DuplicateDetector.swift`, `Sources/LibrarianCore/Search/SimilarityClustering.swift` | Report-only duplicate detection and derived similarity relationships |
| Search | `Sources/LibrarianCore/Search/SearchService.swift` | FTS5 search and optional semantic or visual search |
| Live folder updates | `Sources/LibrarianCore/Indexing/LiveIndexCoordinator.swift` | FSEvents reconciliation and incremental refreshes |
| Review corrections and learning | `ReviewInbox.swift`, `LearnedRules.swift` | Catalog-only corrections and reversible learned rules |
| Virtual organization | `Sources/LibrarianCore/Organization/OrganizationGraph.swift`, `VirtualTree.swift`, `SmartOrganization.swift` | Relationships and groups that do not change Finder |
| Moving files after confirmation | `Sources/LibrarianAppSupport/FileOrganization/OrganizationApplier.swift` | Journaled, undoable Finder moves; this is the exceptional write path |
| The main cleanup screen | `Sources/LibrarianApp/Library/CleanerHomeView.swift` | The simple first-run and cleanup experience |
| The advanced library | `Sources/LibrarianApp/Library/LibraryViews.swift` | Search results, groups, review, duplicates, and other detailed views |
| App state and coordination | `Sources/LibrarianApp/Library/AppEntryPoint.swift` | SwiftUI scenes and the `LibrarianModel` that connects the UI to core services |
| App settings and local model choices | `Sources/LibrarianApp/App/SimpleSettingsView.swift` | User-facing settings and model readiness information |
| Headless checks | `Sources/librarian-cli/main.swift` | Index, search, status, duplicate, graph, and provider smoke commands |
| Packaging and entitlements | `scripts/package_app.sh`, `scripts/audit_entitlements.py` | Release-style app bundles, signing, and sandbox checks |
| End-to-end verification | `scripts/e2e_local.sh`, `docs/VERIFICATION.md` | Local product checks and the limits of hosted CI |

`LibrarianCore` is intentionally one SwiftPM target, organized into feature
folders. The folders are for people, not separate modules: every core source
file still shares one module, so the app, CLI, and tests can use the same
contracts. Start in `SourceAccess` for read-only inputs, `Indexing` for the
pipeline, `Catalog` for stored knowledge, `ContentAnalysis` for derived
signals, `LocalModels` for optional inference, `Search` for finding related
items, and `Organization` for virtual groups.

## Follow one file through the code

For a cleanup started from the GUI, this is the shortest useful trace:

1. `CleanerHomeView` shows the **Clean Up** action and the authorized folders.
2. The view calls `LibrarianModel.startIndexing` in
   `Sources/LibrarianApp/Library/AppEntryPoint.swift`.
3. The model creates an `Indexer` with a `SourceBroker`, `Catalog`, scheduler,
   and the selected optional analysis providers.
4. `Indexer` asks `SourceBroker` to enumerate and read the folder. It captures a
   file identity before doing expensive work and checks it again before commit.
5. Extractors, OCR, classifiers, and optional model providers return derived
   values. They do not receive write-capable source handles.
6. `Catalog` commits the file row, text, classifications, relationships, and
   other derived data in its encrypted database.
7. The model refreshes the dashboard and Smart Groups, which the SwiftUI views
   render. Nothing is moved in Finder during indexing.

For a search, the path is shorter: the UI calls the model, the model asks
`SearchService` for catalog results, and the result rows include the live file
path so the app can reveal a file in Finder. Search does not reorganize files.

## Which document should I read?

| You want to… | Read |
| --- | --- |
| Install and use the app | [README](../README.md) |
| Understand ownership and data flow | [Architecture](ARCHITECTURE.md) |
| Check the read-only, offline, and catalog rules | [Security](SECURITY.md) |
| Run builds, tests, packaging checks, and smoke tests | [Verification](VERIFICATION.md) |
| Contribute a focused change | [Contributing](../CONTRIBUTING.md) |
| Recover from a known problem | [Troubleshooting](troubleshooting/) — begin with the file that matches the symptom |
| Understand packaging or Keychain behavior | [Packaging and launch troubleshooting](troubleshooting/packaging-launch.md) and [Keychain troubleshooting](troubleshooting/keychain-prompts.md) |
| Review model setup and local inference | [Specialist models troubleshooting](troubleshooting/specialist-models.md) |
| Read upstream research or attribution decisions | [Upstream reuse notes](UPSTREAM_REUSE.md) |
| Read old investigation notes | `docs/codex/turn-log.md` — historical context, not current behavior |

The README is the user-facing starting point. Architecture and security are
maintainer references. Verification tells you what a green check actually
proves. Troubleshooting pages describe a particular failure or incident and
should not be treated as a general design specification.

## Directories that need special care

- **`ThirdParty/sqlcipher/`** contains vendored code. Do not replace or update
  it without checking its license, provenance, and the SQLCipher target in
  `Package.swift`.
- **`.build/`** is SwiftPM and Xcode output. It is ignored build state, not
  application source. Delete it only when a clean build is actually needed.
- **Model files and runtimes** belong in the local Application Support area.
  Provisioning scripts may download them, but the app does not silently
  download model weights at runtime.
- **`Entitlements.plist.in` files and packaging scripts** define the sandbox
  and distribution boundary. Small changes there can change what the packaged
  app is allowed to do.
- **Source-file access** must stay behind `SourceBroker`. Do not pass source
  paths or write-capable handles into classifiers, model bridges, or extractors.
- **Catalog writes** should stay inside `Catalog` or an explicitly owned app
  support operation. Do not create a second writable store for convenience.

## A sensible next cleanup, later

The source folders are organizational; they do not change the target or the
runtime boundaries. The next cleanup should be a separate, test-driven refactor
of the two broad implementation files:

- split `Catalog.swift` by responsibility while keeping one public `Catalog`
  facade;
- split `Indexer.swift` into pipeline stages while preserving its public API;
- move `LibrarianModel` out of `AppEntryPoint.swift` into app-model files; and
- split `LibraryViews.swift` into feature-specific view files.

These changes should be made one area at a time, with `swift test` and the
relevant safety tests after each move. The current layout change intentionally
stops before altering private type visibility or runtime behavior.
