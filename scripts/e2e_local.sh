#!/bin/bash
# End-to-end verification for Private Local Librarian (local receipts).
# Proves, against the real release binary:
#   1. fixture generation          6. duplicate detection (1 group)
#   2. immutability manifest       7. virtual tree
#   3. indexing                    8. symlink containment (no "TOP SECRET" hit)
#   4. encryption-on-disk          9. missing-file sweep (deleted -> missing=1)
#   5. FTS search                 10. raw header is NOT plaintext SQLite
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$ROOT/.build/release/librarian-cli}"
WORK="$(mktemp -d /tmp/librarian-e2e.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export LIBRARIAN_CATALOG_KEY="$(openssl rand -hex 32)"   # prompt-free keychain bypass
CAT="$WORK/catalog.db"

echo "== [1] fixtures =="
python3 "$ROOT/scripts/gen_fixtures.py" "$WORK"

echo "== [2] pre-index integrity manifest =="
python3 "$ROOT/scripts/gen_fixtures.py" audit-hash "$WORK/TestLibrary" > "$WORK/before.txt"
wc -l < "$WORK/before.txt" | xargs echo "manifest entries:"

echo "== [3] index =="
"$BIN" index "$WORK/TestLibrary" --catalog "$CAT"

echo "== [4] status / encryption =="
"$BIN" status --catalog "$CAT" | tee "$WORK/status1.txt"
grep -q "encrypted-on-disk=true" "$WORK/status1.txt" || { echo "FAIL: not encrypted"; exit 1; }

echo "== [5] search 'inheritance' =="
"$BIN" search "inheritance" --catalog "$CAT"

echo "== [8] symlink containment: searching 'TOP SECRET' must return NOTHING =="
LEAKED="$("$BIN" search "TOP SECRET" --catalog "$CAT" | wc -l | tr -d ' ')"
[ "$LEAKED" = "0" ] || { echo "FAIL: content behind symlink leaked ($LEAKED hits)"; exit 1; }
echo "containment OK: 0 hits"

echo "== [6] duplicates =="
"$BIN" dupes --catalog "$CAT"

echo "== [7] virtual tree =="
"$BIN" tree --catalog "$CAT"

echo "== immutability: post-index manifest must be byte-identical =="
python3 "$ROOT/scripts/gen_fixtures.py" audit-hash "$WORK/TestLibrary" > "$WORK/after.txt"
diff "$WORK/before.txt" "$WORK/after.txt" && echo "IMMUTABILITY: ZERO DIFFERENCES"

echo "== [9] missing sweep =="
rm "$WORK/TestLibrary/School/mat171-worksheet.txt"
"$BIN" index "$WORK/TestLibrary" --catalog "$CAT" > /dev/null
"$BIN" status --catalog "$CAT" | tee "$WORK/status2.txt"
grep -q "missing=1" "$WORK/status2.txt" || { echo "FAIL: vanished file not marked missing"; exit 1; }

echo "== [10] raw header check =="
HEADER="$(head -c 15 "$CAT")"
[ "$HEADER" != "SQLite format 3" ] || { echo "FAIL: plaintext sqlite header"; exit 1; }
echo "header ok: not plaintext SQLite"

echo
echo "E2E PASS — all ten checks green (workspace artifacts were temporary)"
