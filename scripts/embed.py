#!/usr/bin/env python3
"""
Offline local embedding helper — no network, no telemetry.

Uses downloaded HF checkpoints under Models/ via local_files_only=True.
Called by LibrarianCore/LocalModelBridge.swift as a subprocess.

Usage:
  python3 scripts/embed.py --stdin-image --model clip-vit-base-patch32
  python3 scripts/embed.py --stdin-text --model all-MiniLM-L6-v2
  /path/to/model-runtime/bin/python3 scripts/embed.py --check  # offline readiness check
  python3 scripts/embed.py --worker  # JSONL bytes/text worker

Output: JSON to stdout {"dim":512,"vector":[0.1, ...]} or {"error":"..."}.
Inference stays offline through local_files_only plus the offline environment enforced by the Swift bridge and CI.
"""

import argparse
import hashlib
import importlib.util
import json
import sys
import warnings
from pathlib import Path

import os
ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = Path(os.environ.get(
    "LIBRARIAN_MODELS_DIR",
    str(Path.home() / "Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models"),
)).expanduser()

# Map logical model name -> HF dir + runtime
# clip-vit-base-patch32: CLIP image + text (PyTorch, PIL/numpy preprocessing)
# all-MiniLM-L6-v2: text embedding via sentence_transformers
MODEL_HANDLERS = {
    "clip-vit-base-patch32": "clip",
    "all-MiniLM-L6-v2": "minilm",
}
MODEL_DIMS = {"clip-vit-base-patch32": 512, "all-MiniLM-L6-v2": 384}
PROVENANCE_SCHEMA = 2
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_IMAGE_PIXELS = 50_000_000
MAX_IMAGE_EDGE = 16_384
MAX_TEXT_BYTES = 256 * 1024
MODEL_PROVENANCE = {
    "clip-vit-base-patch32": {
        "hf_id": "openai/clip-vit-base-patch32",
        "revision": "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268",
    },
    "all-MiniLM-L6-v2": {
        "hf_id": "sentence-transformers/all-MiniLM-L6-v2",
        "revision": "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
    },
}

# Lazy singletons — keep model warm within one process invocation (batch mode)
_clip_model = None
_minilm_model = None
_trusted_models = set()


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_relative_path(relative: str) -> bool:
    if not relative or relative.startswith("/") or "\\" in relative:
        return False
    parts = relative.split("/")
    return all(part not in {"", ".", ".."} for part in parts)


def _provenance_valid(model: str, verify_hashes: bool = False) -> bool:
    """Validate a provisioner's identity manifest before loading a checkpoint."""
    spec = MODEL_PROVENANCE.get(model)
    if spec is None:
        return False
    destination = MODELS_DIR / model
    if not destination.is_dir() or destination.is_symlink():
        return False
    try:
        record = json.loads((destination / "provenance.json").read_text())
    except Exception:
        return False
    if not isinstance(record, dict):
        return False
    if (
        record.get("schema") != PROVENANCE_SCHEMA
        or record.get("model") != model
        or any(record.get(key) != value for key, value in spec.items())
    ):
        return False
    expected_files = record.get("expected_files")
    if not isinstance(expected_files, dict) or not expected_files:
        return False
    weights = ("pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack")
    if "config.json" not in expected_files or not any(name in expected_files for name in weights):
        return False
    root = destination.resolve()
    for relative, expected in expected_files.items():
        if (not isinstance(relative, str) or not _safe_relative_path(relative)
                or not isinstance(expected, str)):
            return False
        if len(expected) != 64 or any(c not in "0123456789abcdef" for c in expected.lower()):
            return False
        path = destination / relative
        try:
            path.resolve().relative_to(root)
        except ValueError:
            return False
        if path.is_symlink() or not path.is_file():
            return False
        if verify_hashes and _sha256_file(path) != expected.lower():
            return False
    actual_files = set()
    try:
        for path in destination.rglob("*"):
            if path.is_symlink():
                return False
            if not path.is_file():
                continue
            relative = path.relative_to(destination).as_posix()
            if relative == "provenance.json" or ".cache" in path.relative_to(destination).parts:
                continue
            actual_files.add(relative)
    except OSError:
        return False
    if actual_files != set(expected_files):
        return False
    return True


def _require_model(model: str) -> bool:
    if model not in _trusted_models:
        if not _provenance_valid(model, verify_hashes=True):
            return False
        _trusted_models.add(model)
    return True


def _dependency_status():
    return {
        "torch": importlib.util.find_spec("torch") is not None,
        "transformers": importlib.util.find_spec("transformers") is not None,
        "PIL": importlib.util.find_spec("PIL") is not None,
        "numpy": importlib.util.find_spec("numpy") is not None,
        "sentence_transformers": importlib.util.find_spec("sentence_transformers") is not None,
    }


def _model_dependencies_ready(model: str, dependencies: dict[str, bool]) -> bool:
    required = {
        "clip-vit-base-patch32": ("torch", "transformers", "PIL", "numpy"),
        "all-MiniLM-L6-v2": ("torch", "sentence_transformers", "numpy"),
    }.get(model, ())
    return all(dependencies.get(name, False) for name in required)


def _load_clip():
    global _clip_model
    if _clip_model is not None:
        return _clip_model
    from transformers import CLIPModel, CLIPTokenizer

    _clip_model = CLIPModel.from_pretrained(
        str(MODELS_DIR / "clip-vit-base-patch32"), local_files_only=True
    )
    # Keep tokenizer lazy but warm on first text-CLIP call
    _clip_model._clip_tokenizer = None  # type: ignore[attr-defined]
    try:
        _clip_model._clip_tokenizer = CLIPTokenizer.from_pretrained(  # type: ignore[attr-defined]
            str(MODELS_DIR / "clip-vit-base-patch32"), local_files_only=True
        )
    except Exception:
        pass
    _clip_model.eval()
    return _clip_model


CLIP_IMAGE_SIZE = 224
CLIP_IMAGE_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_IMAGE_STD = (0.26862954, 0.26130258, 0.27577711)


def _clip_pixel_values(image, torch):
    """Apply CLIP's resize/center-crop/normalize contract without torchvision.

    Recent Transformers releases make ``CLIPImageProcessor`` import
    torchvision even for this CPU-only path. Keeping preprocessing here makes
    the runtime contract match the pinned requirements and avoids installing a
    second, tightly coupled vision stack just to resize one image.
    """
    import numpy as np
    from PIL import Image

    width, height = image.size
    scale = CLIP_IMAGE_SIZE / min(width, height)
    resized_width = max(CLIP_IMAGE_SIZE, round(width * scale))
    resized_height = max(CLIP_IMAGE_SIZE, round(height * scale))
    resampling = getattr(Image, "Resampling", Image)
    resized = image.resize((resized_width, resized_height), resample=resampling.BICUBIC)
    left = (resized_width - CLIP_IMAGE_SIZE) // 2
    top = (resized_height - CLIP_IMAGE_SIZE) // 2
    cropped = resized.crop((left, top, left + CLIP_IMAGE_SIZE, top + CLIP_IMAGE_SIZE))
    pixels = torch.from_numpy(np.asarray(cropped, dtype=np.float32)).permute(2, 0, 1).contiguous()
    pixels = pixels / 255.0
    mean = torch.tensor(CLIP_IMAGE_MEAN, dtype=pixels.dtype).view(3, 1, 1)
    std = torch.tensor(CLIP_IMAGE_STD, dtype=pixels.dtype).view(3, 1, 1)
    return ((pixels - mean) / std).unsqueeze(0)


def _load_minilm():
    global _minilm_model
    if _minilm_model is not None:
        return _minilm_model
    from sentence_transformers import SentenceTransformer

    _minilm_model = SentenceTransformer(
        str(MODELS_DIR / "all-MiniLM-L6-v2"), device="cpu", trust_remote_code=False
    )
    return _minilm_model


def _embed_image_bytes(data: bytes, model: str = "clip-vit-base-patch32"):
    """Embed raw image bytes from stdin (broker-only; path never exposed to helper)."""
    if model != "clip-vit-base-patch32":
        return {"error": f"unknown image model {model!r}"}
    if not data:
        return {"error": "empty stdin for image"}
    if len(data) > MAX_IMAGE_BYTES:
        return {"error": "image payload exceeds the 64 MiB embedding ceiling"}
    if not _require_model(model):
        return {"error": f"model is not provenance-verified: {model} — run provision_image_models.py --verify-only"}
    try:
        import io
        import torch
        from PIL import Image

        clip_model = _load_clip()
        try:
            with warnings.catch_warnings():
                warnings.simplefilter("error", Image.DecompressionBombWarning)
                img = Image.open(io.BytesIO(data))
                width, height = img.size
                if width <= 0 or height <= 0 or width > MAX_IMAGE_EDGE or height > MAX_IMAGE_EDGE:
                    raise ValueError("image dimensions exceed the embedding ceiling")
                if width * height > MAX_IMAGE_PIXELS:
                    raise ValueError("image pixel count exceeds the embedding ceiling")
                img.load()
                img = img.convert("RGB")
                img.load()
        except Exception as e:
            return {"error": f"cannot decode image bytes: {e}"}
        with torch.no_grad():
            out = clip_model.get_image_features(pixel_values=_clip_pixel_values(img, torch))
            if hasattr(out, "pooler_output"):
                vec = out.pooler_output[0]
            elif hasattr(out, "image_embeds"):
                vec = out.image_embeds[0]
            else:
                vec = out[0] if len(out.shape) == 2 else out
            vec = vec / vec.norm(p=2).clamp(min=1e-9)
            arr = vec.cpu().tolist()
            return {"dim": len(arr), "vector": arr, "model": model}
    except Exception as e:
        return {"error": f"clip inference failed: {e}"}


def _embed_text_bytes(data: bytes, model: str = "all-MiniLM-L6-v2"):
    """Embed text supplied on stdin (argv-safe)."""
    if model != "all-MiniLM-L6-v2":
        return {"error": f"unknown text model {model!r}"}
    if len(data) > MAX_TEXT_BYTES:
        return {"error": "text payload exceeds the 256 KiB embedding ceiling"}
    if not _require_model(model):
        return {"error": f"model is not provenance-verified: {model} — run provision_image_models.py --verify-only"}
    text = data.decode("utf-8", errors="replace").strip()
    if not text:
        return {"error": "empty text on stdin"}
    try:
        mdl = _load_minilm()
        vec = mdl.encode(text[:4000], convert_to_tensor=False, normalize_embeddings=True)
        arr = vec.tolist() if hasattr(vec, "tolist") else list(vec)
        return {"dim": len(arr), "vector": arr, "model": model}
    except Exception as e:
        return {"error": f"minilm inference failed: {e}"}


def _embed_clip_text_bytes(data: bytes):
    """Natural-language text → CLIP joint space (512-d) for cross-modal image search."""
    dest = MODELS_DIR / "clip-vit-base-patch32"
    if not _require_model("clip-vit-base-patch32"):
        return {"error": "model is not provenance-verified: clip-vit-base-patch32 — run provision_image_models.py --verify-only"}
    if len(data) > MAX_TEXT_BYTES:
        return {"error": "text payload exceeds the 256 KiB embedding ceiling"}
    text = data.decode("utf-8", errors="replace").strip()
    if not text:
        return {"error": "empty text on stdin"}
    try:
        import torch
        clip_model = _load_clip()
        tok = getattr(clip_model, "_clip_tokenizer", None)
        if tok is None:
            from transformers import CLIPTokenizer
            tok = CLIPTokenizer.from_pretrained(str(dest), local_files_only=True)
            clip_model._clip_tokenizer = tok  # type: ignore[attr-defined]
        with torch.no_grad():
            toks = tok([text[:4000]], padding=True, truncation=True, return_tensors="pt")
            out = clip_model.get_text_features(**toks)
            if hasattr(out, "pooler_output"):
                vec = out.pooler_output[0]
            elif hasattr(out, "text_embeds"):
                vec = out.text_embeds[0]
            else:
                vec = out[0] if len(out.shape) == 2 else out
            vec = vec / vec.norm(p=2).clamp(min=1e-9)
            arr = vec.cpu().tolist()
            return {"dim": len(arr), "vector": arr, "model": "clip-vit-base-patch32-text"}
    except Exception as e:
        return {"error": f"clip text inference failed: {e}"}


def main():
    ap = argparse.ArgumentParser(description="Offline embedding helper (no network)")
    ap.add_argument("--stdin-image", action="store_true", help="Read raw image bytes from stdin (broker-only)")
    ap.add_argument("--stdin-text", action="store_true", help="Read UTF-8 text from stdin (argv-safe)")
    ap.add_argument("--stdin-clip-text", action="store_true", help="Read UTF-8 text from stdin and embed into CLIP joint space (512-d)")
    ap.add_argument("--worker", action="store_true", help="Persistent JSONL worker: {op,data} per line -> {dim,vector} per line (image_b64/text/clip_text)")
    ap.add_argument("--model", type=str, default=None, help="Model name for the selected stdin operation")
    ap.add_argument("--check", action="store_true", help="Check runtime deps and exit 0/1")
    args = ap.parse_args()

    if args.check:
        dependencies = _dependency_status()
        trusted = [m for m in MODEL_HANDLERS if _provenance_valid(m, verify_hashes=True)]
        ready = [m for m in trusted if _model_dependencies_ready(m, dependencies)]
        status = "ready" if ready else "unavailable"
        print(json.dumps({
            "status": status,
            "models_dir": str(MODELS_DIR),
            "dimensions": MODEL_DIMS,
            "offline": True,
            "trusted_models": trusted,
            "ready_models": ready,
            "dependencies": dependencies,
        }))
        sys.exit(0 if ready else 1)

    if args.stdin_image:
        model = args.model or "clip-vit-base-patch32"
        data = sys.stdin.buffer.read(MAX_IMAGE_BYTES + 1)
        res = _embed_image_bytes(data, model=model)
        print(json.dumps(res))
        sys.exit(0 if "vector" in res else 1)

    if args.stdin_clip_text:
        data = sys.stdin.buffer.read(MAX_TEXT_BYTES + 1)
        res = _embed_clip_text_bytes(data)
        print(json.dumps(res))
        sys.exit(0 if "vector" in res else 1)

    if args.worker:
        import base64
        # Verify manifests and pre-warm models so per-file latency is inference only.
        try:
            if _require_model("clip-vit-base-patch32"):
                _load_clip()
        except Exception:
            pass
        try:
            if _require_model("all-MiniLM-L6-v2"):
                _load_minilm()
        except Exception:
            pass
        sys.stdout.reconfigure(line_buffering=True)  # type: ignore[attr-defined]
        for raw in sys.stdin:
            raw = raw.strip()
            if not raw:
                continue
            try:
                req = json.loads(raw)
            except Exception as e:
                print(json.dumps({"error": f"bad json: {e}"}), flush=True)
                continue
            op = req.get("op")
            data_field = req.get("data", "")
            if op == "image_b64":
                try:
                    b = base64.b64decode(data_field, validate=True)
                except Exception as e:
                    print(json.dumps({"error": f"bad base64: {e}"}), flush=True)
                    continue
                res = _embed_image_bytes(b, model="clip-vit-base-patch32")
                print(json.dumps(res), flush=True)
            elif op == "text":
                res = _embed_text_bytes(str(data_field).encode("utf-8"), model="all-MiniLM-L6-v2")
                print(json.dumps(res), flush=True)
            elif op == "clip_text":
                res = _embed_clip_text_bytes(str(data_field).encode("utf-8"))
                print(json.dumps(res), flush=True)
            else:
                print(json.dumps({"error": f"unknown op {op!r}"}), flush=True)
        return

    if args.stdin_text:
        model = args.model or "all-MiniLM-L6-v2"
        data = sys.stdin.buffer.read(MAX_TEXT_BYTES + 1)
        res = _embed_text_bytes(data, model=model)
        print(json.dumps(res))
        sys.exit(0 if "vector" in res else 1)

    ap.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
