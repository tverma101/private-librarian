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

usage() {
    cat <<EOF
Usage: $0 [options]

Installs the optional offline Python runtime and downloads the pinned models
used by Private Librarian. Apple Vision remains the zero-download baseline.

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
  LIBRARIAN_BOOTSTRAP_PYTHON  Python 3.11+ used to create the runtime
  LIBRARIAN_APP_SUPPORT_DIR   app support root override
  LIBRARIAN_MODELS_DIR        default model root override
  LIBRARIAN_SPECIALIST_MODELS_DIR specialist model root override
  LIBRARIAN_MODEL_RUNTIME_DIR default runtime directory override
  HF_TOKEN                    optional Hugging Face token for Terminal usage

Security:
  --hf-token-stdin keeps the token out of argv, shell history, generated files,
  and child-process environment variables. The specialist provisioner reads it
  from stdin and supplies it to huggingface_hub from process memory only.
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
    if [ "$INSTALL_SPECIALIST_RUNTIME" -eq 1 ]; then
        "$PYTHON" -m pip install --requirement "$ROOT_DIR/scripts/specialist-requirements.txt"
    fi
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
