# Verification Receipts

All receipts below are from real executed runs on this machine
(macOS 26.6, Apple Silicon, Xcode toolchain Swift 6.3.3), August 21 2026.

## Unit / integration suite

```
$ DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
Executed 21 tests, with 0 failures (0 unexpected) in 1.967 (1.969) seconds
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

## Synthetic library benchmark (Issue #10)

Direct release-binary run on August 23, 2026 with
`python3 scripts/benchmark_librarian.py --files 10000 --search-iters 5`:

```
cold index:       61.39 s   163.0 files/s   26.8 MB RSS   10006 indexed
warm index:        1.079 s  9275.9 files/s  26.8 MB RSS       0 indexed
one-file change:   1.139 s  8783.6 files/s  26.8 MB RSS       1 indexed
duplicate pass:    0.546 s                    2 groups
FTS search:      p50 111.08 ms / p95 112.91 ms
catalog size: 15,904,768 bytes; fixture bytes: 1,202,644
```

The optional 100k run was started against the release binary but cancelled
after roughly 20 minutes without a completed result; no 100k performance claim
is made. The cancellation left no worker process or result artifact.

## Reproduce

```bash
swift build && swift test
bash scripts/e2e_local.sh
scripts/package_app.sh .build/release
python3 scripts/audit_entitlements.py dist/PrivateLibrarian.app
sandbox-exec -f <(printf '(version 1)\n(allow default)\n(deny network*)\n') \
  python3 scripts/network_negative_probe.py
```
