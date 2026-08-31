#!/usr/bin/env bash
set -euo pipefail

# Install the optional local embedding runtime and its two wired checkpoints.
# This script is the supported setup entrypoint; the app itself never performs
# network access or package/model installation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_PYTHON="${LIBRARIAN_BOOTSTRAP_PYTHON:-}"
APP_SUPPORT_DIR="${LIBRARIAN_APP_SUPPORT_DIR:-$HOME/Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian}"
MODELS_DIR="${LIBRARIAN_MODELS_DIR:-$APP_SUPPORT_DIR/Models}"
RUNTIME_DIR="${LIBRARIAN_MODEL_RUNTIME_DIR:-$APP_SUPPORT_DIR/model-runtime}"
MODEL_ARGS=(--all)
FORCE=0
INSTALL_RUNTIME=1
DOWNLOAD_MODELS=1

usage() {
    cat <<EOF
Usage: $0 [options]

Installs the optional offline Python runtime and downloads the pinned models
used by Private Librarian. Apple Vision remains the zero-download baseline.

Options:
  --model NAME       install one wired model
  --all              install both wired models (default)
  --models-dir PATH  model root (default: app support/Models)
  --runtime-dir PATH isolated Python runtime (default: app support/model-runtime)
  --skip-runtime     use an existing Python environment instead of creating one
  --runtime-only     install/update dependencies without downloading models
  --models-only      download models using the selected Python environment
  --force            redownload ready models and preserve their old directories
  -h, --help         show this help

Environment:
  LIBRARIAN_BOOTSTRAP_PYTHON  Python 3.11+ used to create the runtime
  LIBRARIAN_APP_SUPPORT_DIR   app support root override
  LIBRARIAN_MODELS_DIR        default model root override
  LIBRARIAN_MODEL_RUNTIME_DIR default runtime directory override
EOF
}

while (($#)); do
    case "$1" in
        --model)
            [ "$#" -ge 2 ] || { echo "--model needs a name" >&2; exit 2; }
            MODEL_ARGS=(--model "$2")
            shift 2
            ;;
        --all)
            MODEL_ARGS=(--all)
            shift
            ;;
        --models-dir)
            [ "$#" -ge 2 ] || { echo "--models-dir needs a path" >&2; exit 2; }
            MODELS_DIR="$2"
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
            shift
            ;;
        --models-only)
            INSTALL_RUNTIME=0
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

if [ -z "$BASE_PYTHON" ]; then
    for candidate in /usr/local/bin/python3 /opt/homebrew/bin/python3 /usr/bin/python3; do
        if [ -x "$candidate" ]; then
            BASE_PYTHON="$candidate"
            break
        fi
    done
fi

if [ -z "$BASE_PYTHON" ] || [ ! -x "$BASE_PYTHON" ]; then
    echo "No usable Python 3 was found. Set LIBRARIAN_BOOTSTRAP_PYTHON." >&2
    exit 1
fi

PY_VERSION="$($BASE_PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "Using bootstrap Python $PY_VERSION: $BASE_PYTHON"

if [ "$INSTALL_RUNTIME" -eq 1 ]; then
    if [ -e "$RUNTIME_DIR" ] && [ ! -x "$RUNTIME_DIR/bin/python3" ]; then
        echo "Runtime directory exists but is incomplete: $RUNTIME_DIR" >&2
        echo "Choose another --runtime-dir or repair it manually; it was not removed." >&2
        exit 1
    fi
    if [ ! -x "$RUNTIME_DIR/bin/python3" ]; then
        mkdir -p "$(dirname "$RUNTIME_DIR")"
        "$BASE_PYTHON" -m venv "$RUNTIME_DIR"
    fi
    PYTHON="$RUNTIME_DIR/bin/python3"
    "$PYTHON" -m pip install --upgrade pip
    "$PYTHON" -m pip install --requirement "$ROOT_DIR/scripts/model-requirements.txt"
else
    if [ -n "${LIBRARIAN_MODEL_PYTHON:-}" ]; then
        PYTHON="$LIBRARIAN_MODEL_PYTHON"
    elif [ -x "$RUNTIME_DIR/bin/python3" ]; then
        PYTHON="$RUNTIME_DIR/bin/python3"
    else
        PYTHON="$BASE_PYTHON"
    fi
    [ -x "$PYTHON" ] || { echo "Model Python is not executable: $PYTHON" >&2; exit 1; }
fi

if [ "$DOWNLOAD_MODELS" -eq 1 ]; then
    mkdir -p "$MODELS_DIR"
    args=("$ROOT_DIR/scripts/provision_image_models.py" "${MODEL_ARGS[@]}" --models-dir "$MODELS_DIR")
    if [ "$FORCE" -eq 1 ]; then
        args+=(--force)
    fi
    LIBRARIAN_MODELS_DIR="$MODELS_DIR" "$PYTHON" "${args[@]}"
fi

echo "Model runtime: $PYTHON"
echo "Model root: $MODELS_DIR"
echo "Next check: LIBRARIAN_MODELS_DIR=$MODELS_DIR $PYTHON $ROOT_DIR/scripts/embed.py --check"
