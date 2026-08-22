# Security Model

## The one-sentence model

Original files are readable, never writable: every component that can name a
source path is restricted to open-once-`O_RDONLY|O_NOFOLLOW` semantics, and
all "organization" is rows in an encrypted catalog — the system contains no
code path that renames, moves, deletes, re-tags, permission-changes, or
rewrites a source file.

## Threats and controls

| Threat | Control | Verified by |
|---|---|---|
| Buggy model / malicious document tells the AI to delete or exfiltrate | No filesystem-writing capability exists in the source subsystem; classifier output must pass the schema contract wall or be discarded | PromptInjectionTests, ImmutabilityAndSymlinkTests |
| Symlink breakout to files outside the scanned root | Enumeration lstat-checks every child, records links as metadata, never descends; all reads use `O_NOFOLLOW` (ELOOP on TOCTOU swap) | SymlinkEscapeTests (`Forbidden/` lives OUTSIDE the fixture root) |
| Malformed file crashes the indexer (parser bombs) | Extraction is bounded and error-isolated per file; failures become opaque `errors` rows, indexing continues | ResilienceTests (truncated PDF, fake JPEG, corrupt ZIP) |
| Catalog theft | SQLCipher 4.17.0 compiled into the binary (no system libsqlite3 fallback), key = 32 random bytes in the Keychain, never on disk next to the db | encryption tests + `status` header check |
| Wrong key opens old catalog | SQLCipher refuses; tests assert failure, not silent plaintext | ResilienceTests |
| Silent downgrade to unencrypted sqlite | `Catalog.onDiskHeaderIsPlaintextSQLite` checks the on-disk header; CLI prints `encrypted-on-disk=` every run | E2E receipts |
| Duplicate detector deleting "copies" | Detector is report-only by construction — it has no delete API | BehaviorTests assert both copies still exist |
| Deleted originals ghosting in search results | Missing-sweep marks rows `missing`; nothing is reconstructed or deleted twice | ResilienceTests.testOriginalLossIsRecordedNotRepaired |
| Over-broad entitlements in packaged app | App Sandbox ON, `user-selected.read-only`, bookmarks app-scope; auditor fails on any write/network/audio/photos entitlement | scripts/audit_entitlements.py in CI |
| Network exfiltration from the app | No network entitlements; network-negative probe expects all four connection classes DENIED | scripts/network_negative_probe.py |
| Image inference leaks to cloud | All AI image sorting runs 100% on-device: Apple Vision (`VNClassifyImageRequest`/`VNGenerateImageFeaturePrintRequest`) + optional local CoreML models from `Models/`; no network entitlement, no download in CI, no telemetry | VisionImageAnalyzer + provision_image_models.py |

## AI image sorting — privacy note

`VisionImageAnalyzer` uses the **on-device** Vision framework. The model lives in
`/System/Library/Frameworks/Vision.framework`, runs on ANE/GPU via
`VNImageRequestHandler(data:)`, never leaves the process, never hits the
network. The app has **no** `network.client`/`network.server` entitlement —
on-device Vision and optional `Models/*.mlpackage` both work without one.
Downloaded models (CLIP/SigLIP/DINOv2 in `Models/`, gitignored, provisioned via
`scripts/provision_image_models.py --all`) also run locally via Core ML.
`Models/` is outside the indexed tree.

## What is deliberately NOT here yet

- OCR / speech / video sampling (Stage E) — not started.
- LLM-assisted classification — the seam exists (Scheduler slots +
  ClassifierContract wall) but no LLM runs; tag quality is Vision + rules.
- Downloaded CLIP/SigLIP/DINOv2 embeddings — provisionable via
  `scripts/provision_image_models.py --all` (local CoreML, still no network),
  but not wired into Indexer yet; Vision feature-prints handle similarity for now.
- GUI folder-picker flow — SwiftUI shell builds; bookmark flow unexercised.

Honest gaps are tracked in the README status table.
