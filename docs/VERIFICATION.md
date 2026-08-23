# Verification Receipts

All receipts below are from real executed runs on this machine
(macOS 26.6, Apple Silicon, Xcode toolchain Swift 6.3.3), August 21 2026.

## Unit / integration suite

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Executed 36 tests, with 0 failures (0 unexpected)
```

Covers: immutability zero-diff, symlink breakout + broker refusal +
TOCTOU swap, root-spelling contract (`/` and trailing-slash roots never
double-slash), unreadable-directory tolerance (EACCES never counts as
deletion), prompt-injection inertness, malformed-file resilience,
catalog encryption + wrong-key refusal + no plaintext header, duplicate
reporting (near-duplicate control excluded), incremental re-index,
virtual tree multi-label membership, FTS5 search, original-loss → missing.

## End-to-end (scripts/e2e_local.sh, release binary)

```
== [1] fixtures ==            fixtures written under /tmp/librarian-e2e.mDY6Hy/TestLibrary
== [2] pre-index manifest ==  manifest entries: 22
== [3] index ==               indexed 13 files in 0.02s / duplicate groups: 1
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

$ python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app
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

## Embedding provider decision (Issue #11 / #31)

`python3 scripts/bench_providers.py --providers local fileid coreml --output /tmp/bench-providers.json`
is an offline, read-only preflight and benchmark. It reports model/checkpoint
identity, preprocessing identity, expected dimensions, dependency presence,
warm-worker latency, deterministic text-to-image fixture status, retrieval
quality status, and a WINNER/FALLBACK decision. On this checkout the observed
decision is `winner=null`, `fallback=Vision feature-print`: the ignored model
weights exist in the canonical checkout, but the Python runtime packages are
not installed and the Core ML pair is not provisioned.

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
provider remains opt-in and Python remains the fallback until Recall@K is
measured on the shared labeled fixture.

## Reproduce

```bash
swift build && swift test
bash scripts/e2e_local.sh
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```
