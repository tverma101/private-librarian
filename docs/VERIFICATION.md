# Verification Receipts

All receipts below are from real executed runs on this machine
(macOS 26.6, Apple Silicon, Xcode toolchain Swift 6.3.3). The original
baseline receipts are dated August 21 2026; the integrated suite and safety
receipts were re-run August 25 2026.

## Unit / integration suite

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Executed 116 tests, with 0 failures (0 unexpected)
```

Re-run August 28 2026 on the integrated tree including the new
SearchService filter tests and the Tier-2 Indexer→provider→catalog→search
integration test (no model artifacts required; the injected fixture provider
exercises the real seams with unchanged-scan zero work asserted).

Covers: immutability zero-diff, symlink breakout + broker refusal +
TOCTOU swap, root-spelling contract (`/` and trailing-slash roots never
double-slash), unreadable-directory tolerance (EACCES never counts as
deletion), prompt-injection inertness, malformed-file resilience,
catalog encryption + wrong-key refusal + no plaintext header, duplicate
reporting (near-duplicate control excluded), incremental re-index,
virtual tree multi-label membership, FTS5 search, original-loss → missing,
live FSEvents reconciliation, complete decoder snapshots, OCR, media
transcription, screenshot intelligence, similarity families, embeddings,
per-root onboarding coverage, and roadmap foundation behavior.

The quality benchmark's built-in `synthetic-golden-v1` fixture evaluates the
same labeled cases for Python, FileID/OpenCLIP-compatible, and Apple
MobileCLIP provider records. It reports screenshot macro-F1, exact/near
duplicate precision/recall/F1, semantic Recall@10, cluster purity and
completeness, OCR recovery, review precision/coverage, and correction
reduction. Runtime status is kept separate from fixture quality; the
MobileCLIP record remains explicitly unavailable without model artifacts and
an I/O contract fixture.

```
$ python3 scripts/benchmark_quality.py --output /tmp/private-librarian-quality.json
{"schema": 2, "golden_library": "synthetic-golden-v1", ...,
 "provider_comparisons": [{"provider_id": "python-transformers", ...}, ...]}
```

The command emits the complete JSON document; the abbreviated line above
records the observed schema and provider-comparison fields without claiming a
single-line human-readable format.

The live-indexing focused suite also verifies exclusion precedence, dropped-event
full-rescan recovery, and a bounded create/modify/delete sequence delivered by
a real macOS FSEventStream callback (not only synthetic event injection):

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LiveIndexCoordinatorTests
Executed 18 tests, with 0 failures
```

The decoder boundary is covered by `VisionImageTests`: a valid JPEG container
larger than the 8 MiB evidence cap is snapshotted byte-for-byte, while the
same container over the explicit snapshot policy fails closed with
`BrokerError.snapshotTooLarge`. Complete snapshots are bounded by
`SourceBroker.maxSnapshotBytes`; no decoder is given a prefix. The integrated
media decoder uses this same boundary.

The OCR-focused suite also verifies that complete snapshots ignore the normal
evidence read cap and reject an over-policy container instead of returning a
truncated PDF prefix:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter OCRVisionTests
Executed 5 tests, with 0 failures
```
Media verification additionally covers complete snapshot policy, real local
PCM decoding into timestamped chunks, transcript persistence/search, and the
missing-model fail-closed path:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter MediaIntelligenceTests
Executed 16 tests, with 0 failures (one real Whisper integration test is
conditionally skipped when whisper.cpp or the pre-provisioned model is absent)
```

On a host with `/opt/homebrew/bin/whisper-cli` and
`~/Library/Application Support/AI Audio/Models/ggml-base.en.bin`, the real
Whisper integration test uses macOS `say` to create a temporary speech fixture and verifies the
complete path: broker snapshot → ffmpeg stdin → PCM → whisper.cpp → encrypted
transcript row → transcript FTS. The source file is never passed to ffmpeg or
Whisper; only broker-produced bytes cross the decoder boundary.
The roadmap foundation suite also verifies encrypted multi-label graph edges,
catalog-only review corrections with persistent re-index overrides, exclusion
safe onboarding coverage, and dashboard counters:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RoadmapCompletionTests
Executed 10 tests, with 0 failures
```

The learning-loop focused suite verifies evidence-bound correction capture,
three-file promotion, negative-correction blocking, disabled-by-default
rules, and re-index invalidation:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter LearningLoopTests
Executed 7 tests, with 0 failures
```

The provider and search seams are also covered directly:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter Tier2IntegrationTests
Executed 1 test, with 0 failures
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter SearchServiceTests
Executed 1 test, with 0 failures
```

The native UI run loop is available through `script/build_and_run.sh`; it stages
a real `LibrarianApp.app` bundle and supports `--verify` for process startup.
Bookmark resolution, folder-picker interaction, and reauthorization remain
human/UI-bound; the source-safe code path is compile- and startup-verified.

The production targets compile without warnings:

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
Build complete!
```

## End-to-end (scripts/e2e_local.sh, release binary)

```
== [1] fixtures ==            fixtures written under /tmp/librarian-e2e.fTnZaD/TestLibrary
== [2] pre-index manifest ==  manifest entries: 22
== [3] index ==               indexed 13 files in 0.17s / duplicate groups: 1
== [4] status ==              failed=0 indexed=13 missing=0 pending=0 total=13
                              encrypted-on-disk=true
== [5] search inheritance ==  hit csc151-ch4.txt rank=-0.80 …Java [inheritance] explained…
== [8] containment ==         search "TOP SECRET" behind symlink → 0 hits
== [6] dupes ==               duplicate groups: 1
== [7] virtual tree ==        Archives/Assignment/CSC-151/Image/MAT-171/PDF/School/Text populated
== immutability ==            before/after manifests byte-identical — ZERO DIFFERENCES
== [9] missing sweep ==       deleted School/mat171-worksheet.txt, re-indexed:
                              failed=0 indexed=12 missing=1 pending=0 total=13
== [10] raw header ==         not "SQLite format 3" — ciphertext on disk
E2E PASS — all ten checks green
```

(The CoreGraphics log line during indexing is the truncated-PDF fixture being
rejected by PDFKit — parser-crash resilience behaving as designed.)

## Packaging + entitlement audit

```
$ scripts/package_app.sh .build/release
packaged: dist/PrivateLibrarian.app          (codesign adhoc + runtime)

$ python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
ENTITLEMENT AUDIT PASS
  sandbox:           yes
  read-write access: ABSENT (good)
  network client:    ABSENT (good)
  network server:    ABSENT (good)

$ otool -L .build/release/librarian-cli | grep -i sqlite
(no output — system libsqlite3 NOT linked; SQLCipher amalgamation compiled in)
```

## Network-negative probe (sandbox-exec, deny network*)

```
PASS connect example.com:443   DENIED
PASS connect example.com:80    DENIED
PASS connect LAN gateway:53    DENIED
PASS listen on localhost       DENIED
PASS connect localhost:1       DENIED
PASS http fetch                DENIED
NETWORK-NEGATIVE PASS — all attempts denied
```

## Synthetic library benchmark (Issue #10)

Direct release-binary run on August 25, 2026 with
`python3 scripts/benchmark_librarian.py --files 10000 --search-iters 5
--relation-iters 3`:

```
cold index:       72.183 s   138.6 files/s  25.5 MB RSS   10006 indexed
warm index:        1.077 s  9290.8 files/s  25.5 MB RSS       0 indexed
one-file change:   1.127 s  8875.2 files/s  25.5 MB RSS       1 indexed
duplicate pass:    0.533 s                    2 groups
FTS search:      p50 117.52 ms / p95 119.54 ms
graph query:     p50 242.56 ms / p95 244.62 ms
catalog size: 18,243,584 bytes; fixture bytes: 1,202,644
```

The optional 100k run was started against the release binary but cancelled
after roughly 20 minutes without a completed result; no 100k performance claim
is made. The cancellation left no worker process or result artifact.

## Embedding provider decision (Issue #11 / #31)

`python3 scripts/bench_providers.py --providers local fileid coreml --output /tmp/bench-providers.json`
is an offline, read-only preflight and benchmark. It reports model/checkpoint
identity, preprocessing identity, expected dimensions, dependency presence,
warm-worker latency, deterministic text-to-image fixture status, retrieval
quality status, and a WINNER/FALLBACK decision. On the August 25, 2026
checkout run, all three requested providers returned explicit `unavailable`
records: the local Python artifacts have no valid pinned `provenance.json`,
the FileID-compatible ONNX bridge is absent, and the Core ML pair is not
provisioned. The observed decision is `winner=null`, `fallback=Vision
feature-print`; no unverified model is activated or promoted.
Re-provisioning with the pinned scripts is required before treating local
Python artifacts as SHA-verified.

The genuine Core ML path has an executable integration measurement:

```bash
.build/release/librarian-cli provider-smoke --samples 5
```

It either emits an explicit `unavailable` preflight record or loads both
compiled MobileCLIP S0 models, embeds the deterministic red-square PNG and
the query `a red square`, checks matching 512-D space IDs, and reports p50/p95
image/text latency plus cosine similarity. The canonical checkout remains
unprovisioned, so its normal result is the explicit unavailable record.

For the pinned temporary artifact set used to validate the real runtime
boundary (Apple `coreml-mobileclip` revision `3e0a7bfb`, plus the pinned
OpenAI CLIP tokenizer), the receipt was:

```json
{
  "status": "measured",
  "provider": "coreml-mobileclip-s0:apple/coreml-mobileclip@3e0a7bfb:prep-408bdc1b",
  "dimensions": {"image": 512, "text": 512},
  "cold_image_latency_ms": 300.94,
  "cold_text_latency_ms": 107.33,
  "image_latency_ms": {"p50": 64.21, "p95": 64.40},
  "text_latency_ms": {"p50": 65.49, "p95": 66.24},
  "text_to_image_cosine": 0.259351,
  "warm_calls": 5
}
```

This proves genuine bytes-only Core ML inference and matching image/text
dimensions. It is not a Golden Library retrieval-quality win, so the native
provider remains opt-in. A provisioned Python runtime is the comparison
fallback only when it is measured; on this unprovisioned checkout the actual
fallback is the Tier-1 Vision feature-print path until Recall@K is measured
on the shared labeled fixture.

## Reproduce

```bash
swift build -c release && swift test
bash scripts/e2e_local.sh .build/release/librarian-cli
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app --expect-hardened
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```
