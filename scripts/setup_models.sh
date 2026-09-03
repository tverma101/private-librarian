#!/usr/bin/env bash
set -euo pipefail

# Install the optional local embedding/specialist runtime and pinned models.
# This is the supported provisioning entrypoint. It may be launched explicitly
# by the app or from Terminal; normal indexing/inference never calls it.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PYTHON="${LIBRARIAN_BOOTSTRAP_PYTHON:-}"
APP_SUPPORT_DIR="${LIBRARIAN_APP_SUPPORT_DIR:-$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian}"
MODELS_DIR="${LIBRARIAN_MODELS_DIR:-$APP_SUPPORT_DIR/Models}"
SPECIALIST_MODELS_DIR="${LIBRARIAN_SPECIALIST_MODELS_DIR:-$MODELS_DIR/specialists}"
RUNTIME_DIR="${LIBRARIAN_MODEL_RUNTIME_DIR:-$APP_SUPPORT_DIR/model-runtime}"
MODEL_ARGS=(--all)
SPECIALIST_ARGS=()
FORCE=0
INSTALL_RUNTIME=1
DOWNLOAD_MODELS=1
INSTALL_SPECIALIST_RUNTIME=0
DOWNLOAD_SPECIALISTS=0
LEGACY_SELECTION_EXPLICIT=0
RUNTIME_ONLY=0
HF_TOKEN_STDIN=0
HF_TOKEN_VALUE=""

# Clean Macs should not need Homebrew, Xcode, or a global Python install just to
# use a desktop app. When no suitable Python is already available we install a
# pinned python-build-standalone runtime directly into the app's private
# Application Support tree. The archive is checksum-verified before extraction.
BOOTSTRAP_PYTHON_VERSION="3.11.16"
BOOTSTRAP_PYTHON_RELEASE="20260825"
BOOTSTRAP_PYTHON_ARCHIVE="cpython-${BOOTSTRAP_PYTHON_VERSION}+${BOOTSTRAP_PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"
BOOTSTRAP_PYTHON_SHA256="2e50ed6ec49d8714a83c093e9ce74e1b8b21a2c64a49c3b603471d9c4caac76b"
BOOTSTRAP_PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${BOOTSTRAP_PYTHON_RELEASE}/cpython-${BOOTSTRAP_PYTHON_VERSION}%2B${BOOTSTRAP_PYTHON_RELEASE}-aarch64-apple-darwin-install_only.tar.gz"

usage() {
    cat <<EOF
Usage: $0 [options]

Installs the optional offline Python runtime and downloads the pinned models
used by Private Librarian. Apple Vision remains the zero-download baseline.
A clean Apple-silicon Mac can bootstrap the pinned runtime automatically.

Options:
  --model NAME       install one wired model
  --all              install both wired models (default)
  --models-dir PATH  model root (default: app support/Models)
  --specialists-dir PATH
                      specialist model root (default: models-dir/specialists)
  --runtime-dir PATH isolated Python runtime (default: app support/model-runtime)
  --skip-runtime     use an existing Python environment instead of creating one
  --runtime-only     install/update dependencies without downloading models
  --models-only      download models using the selected Python environment
  --specialist-profile PROFILE
                      provision specialist embeddings, balanced, or quality
  --specialist-model NAME
                      provision one specialist checkpoint
  --specialist-runtime-only
                      install specialist dependencies without downloading checkpoints
  --specialist-models-only
                      provision specialists using an existing Python runtime
  --hf-token-stdin   read one Hugging Face token line from stdin for this run only
  --force            redownload ready models and preserve their old directories
  -h, --help         show this help

Environment:
  LIBRARIAN_BOOTSTRAP_PYTHON  optional existing Python 3.10+ used to create the runtime
  LIBRARIAN_APP_SUPPORT_DIR   app support root override
  LIBRARIAN_MODELS_DIR        default model root override
  LIBRARIAN_SPECIALIST_MODELS_DIR specialist model root override
  LIBRARIAN_MODEL_RUNTIME_DIR default runtime directory override
  HF_TOKEN                    optional Hugging Face token for Terminal usage

Security:
  --hf-token-stdin keeps the token out of argv, shell history, generated files,
  and child-process environment variables. The specialist provisioner reads it
  from stdin and supplies it to huggingface_hub from process memory only.
  Automatic Python bootstrap uses one pinned GitHub release URL and verifies
  its SHA-256 before any extracted executable is used.
EOF
}

while (($#)); do
    case "$1" in
        --model)
            [ "$#" -ge 2 ] || { echo "--model needs a name" >&2; exit 2; }
            MODEL_ARGS=(--model "$2")
            LEGACY_SELECTION_EXPLICIT=1
            shift 2
            ;;
        --all)
            MODEL_ARGS=(--all)
            LEGACY_SELECTION_EXPLICIT=1
            shift
            ;;
        --models-dir)
            [ "$#" -ge 2 ] || { echo "--models-dir needs a path" >&2; exit 2; }
            MODELS_DIR="$2"
            if [ "${LIBRARIAN_SPECIALIST_MODELS_DIR:-}" = "" ]; then
                SPECIALIST_MODELS_DIR="$MODELS_DIR/specialists"
            fi
            shift 2
            ;;
        --specialists-dir)
            [ "$#" -ge 2 ] || { echo "--specialists-dir needs a path" >&2; exit 2; }
            SPECIALIST_MODELS_DIR="$2"
            shift 2
            ;;
        --runtime-dir)
            [ "$#" -ge 2 ] || { echo "--runtime-dir needs a path" >&2; exit 2; }
            RUNTIME_DIR="$2"
            shift 2
            ;;
        --skip-runtime)
            INSTALL_RUNTIME=0
            shift
            ;;
        --runtime-only)
            DOWNLOAD_MODELS=0
            RUNTIME_ONLY=1
            shift
            ;;
        --models-only)
            INSTALL_RUNTIME=0
            shift
            ;;
        --specialist-profile)
            [ "$#" -ge 2 ] || { echo "--specialist-profile needs a value" >&2; exit 2; }
            case "$2" in
                embeddings|balanced|quality) ;;
                *) echo "invalid specialist profile: $2" >&2; exit 2 ;;
            esac
            SPECIALIST_ARGS=(--profile "$2")
            DOWNLOAD_SPECIALISTS=1
            INSTALL_SPECIALIST_RUNTIME=1
            shift 2
            ;;
        --specialist-model)
            [ "$#" -ge 2 ] || { echo "--specialist-model needs a name" >&2; exit 2; }
            SPECIALIST_ARGS=(--model "$2")
            DOWNLOAD_SPECIALISTS=1
            INSTALL_SPECIALIST_RUNTIME=1
            shift 2
            ;;
        --specialist-runtime-only)
            INSTALL_SPECIALIST_RUNTIME=1
            DOWNLOAD_MODELS=0
            shift
            ;;
        --specialist-models-only)
            DOWNLOAD_SPECIALISTS=1
            INSTALL_SPECIALIST_RUNTIME=0
            INSTALL_RUNTIME=0
            shift
            ;;
        --hf-token-stdin)
            HF_TOKEN_STDIN=1
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [ "$HF_TOKEN_STDIN" -eq 1 ]; then
    IFS= read -r HF_TOKEN_VALUE || true
    HF_TOKEN_VALUE="${HF_TOKEN_VALUE//$'\r'/}"
    if [ -z "$HF_TOKEN_VALUE" ]; then
        echo "--hf-token-stdin was requested but stdin did not contain a token" >&2
        exit 2
    fi
fi

if [ "$RUNTIME_ONLY" -eq 1 ]; then
    DOWNLOAD_MODELS=0
    DOWNLOAD_SPECIALISTS=0
fi

# A specialist-only invocation must not unexpectedly download the two legacy
# checkpoints as well. Use --all/--model explicitly when both stacks are
# wanted in one run.
if [ "$DOWNLOAD_SPECIALISTS" -eq 1 ] && [ "$LEGACY_SELECTION_EXPLICIT" -eq 0 ]; then
    DOWNLOAD_MODELS=0
fi
if [ "$INSTALL_SPECIALIST_RUNTIME" -eq 1 ] && [ "$INSTALL_RUNTIME" -eq 0 ] && [ "$DOWNLOAD_SPECIALISTS" -eq 0 ]; then
    echo "--specialist-runtime-only cannot be combined with --models-only/--skip-runtime" >&2
    exit 2
fi

python_is_usable() {
    local candidate="$1"
    [ -x "$candidate" ] || return 1
    "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' >/dev/null 2>&1
}

bootstrap_standalone_python() {
    if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
        echo "Automatic local-AI runtime setup currently supports Apple-silicon macOS." >&2
        echo "Set LIBRARIAN_BOOTSTRAP_PYTHON to an existing Python 3.10+ on this Mac." >&2
        return 1
    fi

    for tool in /usr/bin/curl /usr/bin/shasum /usr/bin/tar; do
        [ -x "$tool" ] || { echo "Required macOS tool is missing: $tool" >&2; return 1; }
    done

    local parent temp_dir archive actual_sha extracted_python
    parent="$(dirname "$RUNTIME_DIR")"
    mkdir -p "$parent"
    temp_dir="$(mktemp -d "$parent/.private-librarian-python.XXXXXX")"
    archive="$temp_dir/$BOOTSTRAP_PYTHON_ARCHIVE"

    cleanup_python_bootstrap() {
        rm -rf "$temp_dir"
    }
    trap cleanup_python_bootstrap RETURN

    echo "Preparing Private Librarian's local AI runtime…"
    /usr/bin/curl \
        --fail \
        --location \
        --proto '=https' \
        --tlsv1.2 \
        --retry 3 \
        --retry-delay 1 \
        --output "$archive" \
        "$BOOTSTRAP_PYTHON_URL"

    actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{print $1}')"
    if [ "$actual_sha" != "$BOOTSTRAP_PYTHON_SHA256" ]; then
        echo "Pinned Python runtime checksum mismatch; refusing to execute it." >&2
        echo "Expected: $BOOTSTRAP_PYTHON_SHA256" >&2
        echo "Actual:   $actual_sha" >&2
        return 1
    fi

    /usr/bin/tar -xzf "$archive" -C "$temp_dir"
    extracted_python="$temp_dir/python/bin/python3"
    python_is_usable "$extracted_python" || {
        echo "Verified Python archive did not contain a usable python/bin/python3." >&2
        return 1
    }

    if [ -e "$RUNTIME_DIR" ]; then
        echo "Runtime directory appeared during setup and was left untouched: $RUNTIME_DIR" >&2
        return 1
    fi
    mv "$temp_dir/python" "$RUNTIME_DIR"
    echo "Installed pinned Python $BOOTSTRAP_PYTHON_VERSION runtime for Private Librarian."
    trap - RETURN
    rm -rf "$temp_dir"
}

PYTHON=""

# Reuse a previously prepared app-private runtime before looking for any global
# dependency. This makes second launch and offline inference independent of the
# user's shell environment.
if python_is_usable "$RUNTIME_DIR/bin/python3"; then
    PYTHON="$RUNTIME_DIR/bin/python3"
fi

if [ -z "$PYTHON" ] && [ "$INSTALL_RUNTIME" -eq 1 ]; then
    if [ -n "$BASE_PYTHON" ] && ! python_is_usable "$BASE_PYTHON"; then
        echo "LIBRARIAN_BOOTSTRAP_PYTHON is not a usable Python 3.10+: $BASE_PYTHON" >&2
        exit 1
    fi

    if [ -z "$BASE_PYTHON" ]; then
        for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
            if python_is_usable "$candidate"; then
                BASE_PYTHON="$candidate"
                break
            fi
        done
    fi

    if [ -e "$RUNTIME_DIR" ] && [ ! -x "$RUNTIME_DIR/bin/python3" ]; then
        echo "Runtime directory exists but is incomplete: $RUNTIME_DIR" >&2
        echo "Private Librarian left it untouched instead of deleting unknown files." >&2
        exit 1
    fi

    if [ -n "$BASE_PYTHON" ]; then
        mkdir -p "$(dirname "$RUNTIME_DIR")"
        echo "Preparing Private Librarian's local AI runtime from Python: $BASE_PYTHON"
        "$BASE_PYTHON" -m venv "$RUNTIME_DIR"
    else
        bootstrap_standalone_python
    fi
    PYTHON="$RUNTIME_DIR/bin/python3"
fi

if [ -z "$PYTHON" ]; then
    if [ -n "${LIBRARIAN_MODEL_PYTHON:-}" ] && python_is_usable "$LIBRARIAN_MODEL_PYTHON"; then
        PYTHON="$LIBRARIAN_MODEL_PYTHON"
    elif python_is_usable "$RUNTIME_DIR/bin/python3"; then
        PYTHON="$RUNTIME_DIR/bin/python3"
    elif [ -n "$BASE_PYTHON" ] && python_is_usable "$BASE_PYTHON"; then
        PYTHON="$BASE_PYTHON"
    else
        for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
            if python_is_usable "$candidate"; then
                PYTHON="$candidate"
                break
            fi
        done
    fi
fi

[ -n "$PYTHON" ] && python_is_usable "$PYTHON" || {
    echo "No usable model Python is available. Run setup without --skip-runtime first." >&2
    exit 1
}

PY_VERSION="$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"
echo "Using model Python $PY_VERSION: $PYTHON"

if [ "$INSTALL_RUNTIME" -eq 1 ]; then
    "$PYTHON" -m pip install --upgrade pip
    "$PYTHON" -m pip install --requirement "$ROOT_DIR/scripts/model-requirements.txt"
    if [ "$INSTALL_SPECIALIST_RUNTIME" -eq 1 ]; then
        "$PYTHON" -m pip install --requirement "$ROOT_DIR/scripts/specialist-requirements.txt"
    fi
fi

run_public_provisioner() {
    "$PYTHON" "$@"
}

run_specialist_provisioner() {
    if [ -n "$HF_TOKEN_VALUE" ]; then
        # The credential crosses into Python only on stdin. Do not export it:
        # environment variables are observable process metadata on many hosts.
        printf '%s\n' "$HF_TOKEN_VALUE" \
            | "$PYTHON" "$@" --hf-token-stdin
    else
        # Terminal users may rely on the normal Hugging Face CLI token/cache or
        # an externally supplied HF_TOKEN. The app path always uses stdin.
        "$PYTHON" "$@"
    fi
}

if [ "$DOWNLOAD_MODELS" -eq 1 ]; then
    mkdir -p "$MODELS_DIR"
    args=("$ROOT_DIR/scripts/provision_image_models.py" "${MODEL_ARGS[@]}" --models-dir "$MODELS_DIR")
    if [ "$FORCE" -eq 1 ]; then
        args+=(--force)
    fi
    LIBRARIAN_MODELS_DIR="$MODELS_DIR" run_public_provisioner "${args[@]}"
fi

if [ "$DOWNLOAD_SPECIALISTS" -eq 1 ]; then
    mkdir -p "$SPECIALIST_MODELS_DIR"
    specialist_args=("$ROOT_DIR/scripts/provision_specialist_models.py" "${SPECIALIST_ARGS[@]}" --models-dir "$SPECIALIST_MODELS_DIR")
    if [ "$FORCE" -eq 1 ]; then
        specialist_args+=(--force)
    fi
    LIBRARIAN_SPECIALIST_MODELS_DIR="$SPECIALIST_MODELS_DIR" run_specialist_provisioner "${specialist_args[@]}"
fi

# Do not retain a stdin-supplied credential any longer than this process needs.
HF_TOKEN_VALUE=""
unset HF_TOKEN_VALUE

echo "Model runtime: $PYTHON"
echo "Model root: $MODELS_DIR"
echo "Specialist model root: $SPECIALIST_MODELS_DIR"
echo "Next check: LIBRARIAN_MODELS_DIR=$MODELS_DIR $PYTHON $ROOT_DIR/scripts/embed.py --check"
echo "Specialist check: LIBRARIAN_SPECIALIST_MODELS_DIR=$SPECIALIST_MODELS_DIR $PYTHON $ROOT_DIR/scripts/specialist.py --check"
