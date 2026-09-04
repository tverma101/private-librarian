#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/private-librarian-cancel-test.XXXXXX")"
SETUP_PID=""
CHILD_PID=""

cleanup() {
    if [ -n "$SETUP_PID" ]; then
        kill -TERM "$SETUP_PID" 2>/dev/null || true
        wait "$SETUP_PID" 2>/dev/null || true
    fi
    if [ -n "$CHILD_PID" ]; then
        kill -TERM "$CHILD_PID" 2>/dev/null || true
        wait "$CHILD_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

FAKE_PYTHON="$TEMP_DIR/fake-python"
CHILD_PID_FILE="$TEMP_DIR/child.pid"
LOG_FILE="$TEMP_DIR/setup.log"

cat > "$FAKE_PYTHON" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# setup_models.sh probes Python with `-c` before running a provisioner. Pretend
# to be a valid Python 3.11 runtime without touching the network or filesystem.
if [ "${1:-}" = "-c" ]; then
    if [[ "${2:-}" == *"print(f"* ]]; then
        printf '3.11.0\n'
    fi
    exit 0
fi

printf '%s\n' "$$" > "$FAKE_CHILD_PID_FILE"
# Keep the same PID so a successful cancellation must terminate this exact
# child rather than merely killing a wrapper and orphaning its work.
exec /bin/sleep 30
EOF
chmod +x "$FAKE_PYTHON"

export LIBRARIAN_MODEL_PYTHON="$FAKE_PYTHON"
export LIBRARIAN_APP_SUPPORT_DIR="$TEMP_DIR/app-support"
export LIBRARIAN_MODELS_DIR="$TEMP_DIR/models"
export LIBRARIAN_SPECIALIST_MODELS_DIR="$TEMP_DIR/models/specialists"
export LIBRARIAN_MODEL_RUNTIME_DIR="$TEMP_DIR/runtime"
export FAKE_CHILD_PID_FILE="$CHILD_PID_FILE"

/bin/bash "$ROOT_DIR/scripts/setup_models.sh" --models-only --all >"$LOG_FILE" 2>&1 &
SETUP_PID=$!

# Wait only long enough for the fake provisioner to start. If setup never gets
# there, fail instead of sleeping for the fake command's full 30 seconds.
for _ in $(seq 1 100); do
    if [ -s "$CHILD_PID_FILE" ]; then
        break
    fi
    if ! kill -0 "$SETUP_PID" 2>/dev/null; then
        cat "$LOG_FILE" >&2
        echo "setup exited before the cancellable child started" >&2
        exit 1
    fi
    /bin/sleep 0.05
done

[ -s "$CHILD_PID_FILE" ] || {
    cat "$LOG_FILE" >&2
    echo "timed out waiting for cancellable setup child" >&2
    exit 1
}
CHILD_PID="$(cat "$CHILD_PID_FILE")"

kill -TERM "$SETUP_PID"
set +e
wait "$SETUP_PID"
STATUS=$?
set -e
SETUP_PID=""

if [ "$STATUS" -ne 130 ]; then
    cat "$LOG_FILE" >&2
    echo "expected setup cancellation status 130, got $STATUS" >&2
    exit 1
fi

if kill -0 "$CHILD_PID" 2>/dev/null; then
    echo "setup cancellation orphaned child PID $CHILD_PID" >&2
    exit 1
fi
CHILD_PID=""

grep -F '__LIBRARIAN_SETUP_STAGE__|cancelling|Stopping setup safely' "$LOG_FILE" >/dev/null
if grep -F '__LIBRARIAN_SETUP_STAGE__|complete|' "$LOG_FILE" >/dev/null; then
    cat "$LOG_FILE" >&2
    echo "cancelled setup incorrectly continued to completion" >&2
    exit 1
fi

printf 'setup cancellation contract: PASS\n'
