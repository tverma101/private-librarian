#!/usr/bin/env python3
"""Offline specialist-model worker for Private Librarian.

Security contract:
- runtime network is disabled by environment before any ML library import;
- only provenance-verified local snapshots are loaded;
- source filesystem paths are never accepted by the JSON protocol;
- images arrive as broker-owned bytes, text as bounded derived strings;
- temporary files, when a third-party OCR API requires one, live in a private temp dir;
- generative output is parsed into a tiny schema and arbitrary model-created folders are rejected.

CI can run `python3 scripts/specialist.py --syntax-check` without model dependencies.
"""
from __future__ import annotations

import argparse
import base64
import gc
import hashlib
import importlib
import io
import json
import math
import os
import re
import shutil
import sys
import tempfile
import warnings
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_DATASETS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

ROOT = Path(__file__).resolve().parent.parent


def _model_roots() -> list[Path]:
    candidates: list[Path] = []
    configured = os.environ.get("LIBRARIAN_SPECIALIST_MODELS_DIRS", "")
    if configured:
        candidates.extend(Path(value) for value in configured.split(os.pathsep) if value)
    single = os.environ.get("LIBRARIAN_SPECIALIST_MODELS_DIR")
    if single:
        candidates.append(Path(single))
    candidates.append(ROOT / "Models" / "specialists")
    result: list[Path] = []
    seen: set[str] = set()
    for value in candidates:
        key = str(value.expanduser().resolve())
        if key not in seen:
            seen.add(key)
            result.append(Path(key))
    return result


MODELS_ROOTS = _model_roots()
MODELS_ROOT = MODELS_ROOTS[0]
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_IMAGE_PIXELS = 50_000_000
MAX_IMAGE_EDGE = 16_384
MAX_TEXT_CHARS = 16_000
MAX_OUTPUT_CHARS = 8_192
# Batch inference is benchmark-only for now. Keep both the count and aggregate
# decoded byte budget bounded so a benchmark request cannot turn into an
# accidental unified-memory stress test before we have target-Mac measurements.
MAX_BATCH_IMAGES = 8
MAX_BATCH_RAW_BYTES = 64 * 1024 * 1024

MODEL_SPECS = {
    "siglip2-base-naflex": ("google/siglip2-base-patch16-naflex", "b53b807"),
    "siglip2-so400m-naflex": ("google/siglip2-so400m-patch16-naflex", "cc24074"),
    "dinov3-vitb16-lvd1689m": ("facebook/dinov3-vitb16-pretrain-lvd1689m", "5931719"),
    "paddleocr-vl-1.6": ("PaddlePaddle/PaddleOCR-VL-1.6", "cdc88f5"),
    "minicpm-v-4.6": ("openbmb/MiniCPM-V-4.6", "8169864"),
    "lfm2.5-vl-3b": ("LiquidAI/LFM2.5-VL-3B", "5a414ea"),
}

RUNTIME_MODULES = {
    "siglip2-base-naflex": ("PIL", "torch", "transformers", "accelerate", "safetensors"),
    "siglip2-so400m-naflex": ("PIL", "torch", "transformers", "accelerate", "safetensors"),
    "dinov3-vitb16-lvd1689m": ("PIL", "torch", "transformers", "accelerate", "safetensors"),
    "paddleocr-vl-1.6": ("PIL", "paddle", "paddleocr"),
    "minicpm-v-4.6": ("PIL", "torch", "transformers", "accelerate", "safetensors"),
    "lfm2.5-vl-3b": ("PIL", "torch", "transformers", "accelerate", "safetensors"),
}

ALLOWED_CATEGORIES = {
    "Image", "Image/Animals", "Image/Vehicles", "Image/Scenery", "Image/Food", "Image/Documents",
    "Screenshots", "Screenshots/code", "Screenshots/school", "Screenshots/lms", "Screenshots/receipt",
    "Screenshots/error", "Screenshots/conversation", "Screenshots/social", "Screenshots/map",
    "Screenshots/meme", "Screenshots/reference", "School", "Projects/Code", "Documents/PDF",
    "Documents/Text", "Documents/Office", "Archives", "DiskImages", "Applications", "Packages", "Review",
}

_CACHE = {}
_TRUSTED = set()
_TRUSTED_ROOTS: dict[str, Path] = {}

# Keep only the cheap image encoders warm. OCR/reasoners/VLMs are transient and
# must never overlap each other or the warm encoder set on a memory-constrained Mac.
SIGLIP_MODELS = {
    "siglip2-base-naflex",
    "siglip2-so400m-naflex",
}
WARM_MODELS = SIGLIP_MODELS | {"dinov3-vitb16-lvd1689m"}
TRANSIENT_MODELS = {
    "paddleocr-vl-1.6",
    "minicpm-v-4.6",
    "lfm2.5-vl-3b",
}
OFFLOADABLE_MODELS = {
    "minicpm-v-4.6",
    "lfm2.5-vl-3b",
}
OFFLOAD_ROOT = Path(os.environ.get(
    "LIBRARIAN_SPECIALIST_OFFLOAD_DIR",
    str(Path(tempfile.gettempdir()) / "private-librarian-model-offload"),
))


def unsupported_reason(model_id: str) -> str | None:
    if model_id == "paddleocr-vl-1.6" and sys.platform == "darwin":
        return "PaddleOCR-VL is not supported on macOS CPU/Apple silicon; use the native Vision OCR path."
    return None


def runtime_check(model_id: str) -> tuple[bool, str]:
    reason = unsupported_reason(model_id)
    if reason:
        return False, reason
    modules = RUNTIME_MODULES.get(model_id)
    if modules is None:
        return False, f"unknown specialist model {model_id!r}"
    for module in modules:
        try:
            importlib.import_module(module)
        except Exception as exc:
            return False, f"missing or unusable Python module {module}: {exc}"
    return True, "required specialist runtime modules are available"


def _clear_accelerator_cache() -> None:
    gc.collect()
    try:
        import torch
        if hasattr(torch, "mps") and hasattr(torch.mps, "empty_cache"):
            torch.mps.empty_cache()
        if hasattr(torch, "cuda") and torch.cuda.is_available():
            torch.cuda.empty_cache()
    except Exception:
        pass


def _drop_cached_models(keep: set[str] | None = None) -> None:
    keep = keep or set()
    for model_id in list(_CACHE):
        if model_id not in keep:
            _CACHE.pop(model_id, None)
            _TRUSTED.discard(model_id)
            _TRUSTED_ROOTS.pop(model_id, None)
            _remove_offload(model_id)
    _clear_accelerator_cache()


def _remove_offload(model_id: str) -> None:
    target = OFFLOAD_ROOT / model_id
    try:
        if target.is_symlink() or target.is_file():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
    except FileNotFoundError:
        pass


def _prepare_for_model(model_id: str) -> None:
    if model_id in TRANSIENT_MODELS:
        # A transient specialist gets the machine to itself. This is the key RAM invariant:
        # SigLIP/DINO/Paddle/LLMs/VLMs never stack during an escalation batch.
        _drop_cached_models()
        return

    keep = set(_CACHE) & WARM_MODELS
    if model_id in SIGLIP_MODELS:
        # Base and So400m produce incompatible semantic spaces. Keep DINO plus
        # this exact semantic encoder, but evict the alternate SigLIP before
        # loading so a 16-GB Mac never stacks both checkpoints.
        keep -= SIGLIP_MODELS - {model_id}
    if set(_CACHE) != keep:
        _drop_cached_models(keep=keep)


def _warm_encoder_target(torch_module, platform: str | None = None):
    """Choose the efficient warm-encoder backend without importing torch in CI.

    The target Mac has one unified memory pool, so loading a large encoder in
    FP32 on CPU wastes both bandwidth and RAM. On Apple silicon use MPS + FP16;
    on unsupported hosts retain the conservative CPU/FP32 behavior.
    """
    platform = sys.platform if platform is None else platform
    if platform == "darwin":
        try:
            if hasattr(torch_module.backends, "mps") and torch_module.backends.mps.is_available():
                return "mps", torch_module.float16
        except Exception:
            pass
    return "cpu", None


def _warm_encoder_load_kwargs(torch_module) -> tuple[str, dict]:
    target, dtype = _warm_encoder_target(torch_module)
    kwargs = {"low_cpu_mem_usage": True}
    if dtype is not None:
        kwargs["torch_dtype"] = dtype
    return target, kwargs


def _move_encoder_inputs(inputs, model, torch_module):
    """Move processor tensors to the encoder and match floating input dtype."""
    try:
        parameter = next(model.parameters())
        device = parameter.device
        dtype = parameter.dtype
    except Exception:
        device = getattr(model, "device", None)
        dtype = None
    if device is None:
        return inputs

    moved = {}
    for key, value in inputs.items():
        if not hasattr(value, "to"):
            moved[key] = value
            continue
        try:
            if dtype is not None and torch_module.is_floating_point(value):
                moved[key] = value.to(device=device, dtype=dtype)
            else:
                moved[key] = value.to(device=device)
        except TypeError:
            moved[key] = value.to(device)
    return moved


def _large_model_load_kwargs(model_id: str) -> dict:
    # Hard target-Mac rule: no supported transient model may silently load FP32.
    # Apple Silicon CPU/GPU share unified memory, so swapping layers to CPU is not
    # a substitute for fitting the model. Keep the supported 3B fallback in FP16.
    import torch
    kwargs = {"low_cpu_mem_usage": True}
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        kwargs["torch_dtype"] = torch.float16
    if model_id not in OFFLOADABLE_MODELS:
        return kwargs
    offload = OFFLOAD_ROOT / model_id
    offload.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Apple Silicon uses unified memory, so CPU layer offload does not create a second RAM pool.
    # We still provide a disk-offload folder for oversized quality-tier checkpoints and let
    # Transformers/Accelerate choose it when the device map requires disk placement.
    kwargs.update({
        "device_map": "auto",
        "offload_folder": str(offload),
        "offload_state_dict": True,
    })
    return kwargs


def _memory_policy_self_test() -> None:
    # Dependency-free invariant test used by CI. Transient escalation evicts
    # every warm encoder, DINO may coexist with one semantic encoder, and the
    # two incompatible SigLIP variants are mutually exclusive.
    _CACHE.clear()
    _CACHE["siglip2-base-naflex"] = object()
    _CACHE["dinov3-vitb16-lvd1689m"] = object()
    _prepare_for_model("minicpm-v-4.6")
    if _CACHE:
        raise RuntimeError("transient model did not evict warm model cache")

    _CACHE["siglip2-base-naflex"] = object()
    _prepare_for_model("dinov3-vitb16-lvd1689m")
    if set(_CACHE) != {"siglip2-base-naflex"}:
        raise RuntimeError("DINO preparation evicted compatible semantic encoder")

    _CACHE["dinov3-vitb16-lvd1689m"] = object()
    _prepare_for_model("siglip2-so400m-naflex")
    if set(_CACHE) != {"dinov3-vitb16-lvd1689m"}:
        raise RuntimeError("So400m preparation did not evict Base")

    _CACHE["siglip2-so400m-naflex"] = object()
    _prepare_for_model("siglip2-base-naflex")
    if set(_CACHE) != {"dinov3-vitb16-lvd1689m"}:
        raise RuntimeError("Base preparation did not evict So400m while retaining DINO")
    _CACHE.clear()


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _model_dir(model_id: str) -> Path:
    if model_id not in MODEL_SPECS:
        raise ValueError(f"unknown specialist model {model_id!r}")
    trusted = _TRUSTED_ROOTS.get(model_id)
    if trusted is not None and trusted.is_dir() and not trusted.is_symlink():
        return trusted
    for root in MODELS_ROOTS:
        candidate = root / model_id
        if candidate.is_dir() and not candidate.is_symlink():
            return candidate
    return MODELS_ROOT / model_id


def _safe_relative_path(relative: str) -> bool:
    if not relative or relative.startswith("/") or "\\" in relative:
        return False
    parts = relative.split("/")
    return all(part not in {"", ".", ".."} for part in parts)


def _actual_snapshot_paths(root: Path) -> set[str]:
    actual: set[str] = set()
    if not root.is_dir() or root.is_symlink():
        return actual
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError(f"symlink is not allowed in trusted model snapshot: {path}")
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        if relative == "provenance.json" or ".cache" in path.relative_to(root).parts:
            continue
        actual.add(relative)
    return actual


def _verify_snapshot_at(model_id: str, root: Path, verify_hashes: bool) -> bool:
    hf_id, revision_prefix = MODEL_SPECS[model_id]
    try:
        record = json.loads((root / "provenance.json").read_text(encoding="utf-8"))
    except Exception:
        return False
    revision = record.get("revision")
    expected = record.get("expected_files")
    if (
        record.get("schema") != 1
        or record.get("model") != model_id
        or record.get("hf_id") != hf_id
        or not isinstance(revision, str)
        or len(revision) != 40
        or not revision.startswith(revision_prefix)
        or not isinstance(expected, dict)
        or not expected
    ):
        return False
    resolved_root = root.resolve()
    for relative, wanted in expected.items():
        if (
            not isinstance(relative, str)
            or not isinstance(wanted, str)
            or not _safe_relative_path(relative)
            or re.fullmatch(r"[0-9a-fA-F]{64}", wanted) is None
        ):
            return False
        path = root / relative
        try:
            path.resolve().relative_to(resolved_root)
        except ValueError:
            return False
        if not path.is_file() or path.is_symlink():
            return False
        if verify_hashes and _sha256(path) != wanted.lower():
            return False
    try:
        if _actual_snapshot_paths(root) != set(expected):
            return False
    except (OSError, ValueError):
        return False
    return True


def _verify_snapshot(model_id: str, verify_hashes: bool = True) -> bool:
    if unsupported_reason(model_id):
        return False
    if model_id not in MODEL_SPECS:
        return False
    if verify_hashes and model_id in _TRUSTED:
        return True
    for root in MODELS_ROOTS:
        candidate = root / model_id
        if not candidate.is_dir() or candidate.is_symlink():
            continue
        if _verify_snapshot_at(model_id, candidate, verify_hashes):
            if verify_hashes:
                _TRUSTED.add(model_id)
                _TRUSTED_ROOTS[model_id] = candidate
            return True
    return False


def _decode_image(value: str):
    raw = base64.b64decode(value, validate=True)
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("image payload is empty or exceeds the 64 MiB specialist ceiling")
    from PIL import Image
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            image = Image.open(io.BytesIO(raw))
            width, height = image.size
            if width <= 0 or height <= 0 or width > MAX_IMAGE_EDGE or height > MAX_IMAGE_EDGE:
                raise ValueError("image dimensions exceed the specialist ceiling")
            if width * height > MAX_IMAGE_PIXELS:
                raise ValueError("image pixel count exceeds the specialist ceiling")
            image.load()
            image = image.convert("RGB")
            image.load()
            return raw, image
    except Exception as exc:
        raise ValueError("invalid or oversized image payload") from exc


def _embedding_tensor(value):
    """Extract a tensor from the output variants used by Transformers.

    Transformers 5 changed SigLIP's ``get_*_features`` helpers to return
    ``BaseModelOutputWithPooling`` instead of a raw tensor. Older releases and
    the full ``SiglipOutput`` use different field names, so keep compatibility
    handling in one place before normalization.
    """
    for attribute in ("image_embeds", "text_embeds", "pooler_output"):
        candidate = getattr(value, attribute, None)
        if candidate is not None:
            return candidate
    if isinstance(value, dict):
        for key in ("image_embeds", "text_embeds", "pooler_output"):
            candidate = value.get(key)
            if candidate is not None:
                return candidate
    if isinstance(value, (tuple, list)):
        if not value:
            return value
        return value[-1]
    hidden = getattr(value, "last_hidden_state", None)
    if hidden is not None:
        return hidden[:, 0]
    return value


def _normalize_tensor_rows(vector) -> list[list[float]]:
    """L2-normalize one or more embedding rows without collapsing the batch."""
    vector = _embedding_tensor(vector)
    if hasattr(vector, "detach"):
        vector = vector.detach()
    ndim = getattr(vector, "ndim", 1)
    if ndim == 1:
        vector = vector.unsqueeze(0)
    elif ndim != 2:
        raise ValueError("embedding output must be rank 1 or 2")
    vector = vector.float()
    norms = vector.norm(p=2, dim=-1, keepdim=True)
    norm_values = norms.detach().float().cpu().reshape(-1).tolist()
    if not norm_values or any(not math.isfinite(float(value)) or float(value) <= 0 for value in norm_values):
        raise ValueError("non-finite/zero embedding")
    rows = (vector / norms).cpu().tolist()
    normalized: list[list[float]] = []
    for row in rows:
        values = [float(value) for value in row]
        if not values or any(not math.isfinite(value) for value in values):
            raise ValueError("invalid embedding values")
        normalized.append(values)
    return normalized


def _normalize_tensor(vector) -> list[float]:
    rows = _normalize_tensor_rows(vector)
    if len(rows) != 1:
        raise ValueError("single embedding operation returned multiple rows")
    return rows[0]


def _load_siglip(key: str):
    if key not in SIGLIP_MODELS:
        raise ValueError(f"model is not a configured SigLIP encoder: {key!r}")
    if key in _CACHE:
        return _CACHE[key]
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    _prepare_for_model(key)
    import torch
    from transformers import AutoModel, AutoProcessor
    path = str(_model_dir(key))
    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    target, load_kwargs = _warm_encoder_load_kwargs(torch)
    model = AutoModel.from_pretrained(
        path, local_files_only=True, trust_remote_code=False, **load_kwargs)
    if target == "mps":
        model = model.to("mps")
    model.eval()
    _CACHE[key] = (model, processor)
    return model, processor


def _siglip_images(images, model_id: str) -> list[list[float]]:
    if not images or len(images) > MAX_BATCH_IMAGES:
        raise ValueError(f"SigLIP batch must contain 1..{MAX_BATCH_IMAGES} images")
    import torch
    model, processor = _load_siglip(model_id)
    with torch.inference_mode():
        inputs = _move_encoder_inputs(
            processor(images=images, return_tensors="pt"), model, torch)
        if hasattr(model, "get_image_features"):
            vector = model.get_image_features(**inputs)
        else:
            output = model(**inputs)
            vector = getattr(output, "image_embeds", None)
            if vector is None:
                vector = getattr(output, "pooler_output", None)
            if vector is None:
                raise RuntimeError("SigLIP2 runtime exposed no image embedding")
    rows = _normalize_tensor_rows(vector)
    if len(rows) != len(images):
        raise RuntimeError("SigLIP2 batch output count did not match input count")
    return rows


def _siglip_image(image, model_id: str) -> dict:
    values = _siglip_images([image], model_id)[0]
    return {"model": model_id, "space": f"{model_id}-joint", "dim": len(values), "vector": values}


def _siglip_text(text: str, model_id: str) -> dict:
    import torch
    model, processor = _load_siglip(model_id)
    with torch.inference_mode():
        inputs = _move_encoder_inputs(
            processor(text=[text[:MAX_TEXT_CHARS]], padding="max_length", return_tensors="pt"),
            model, torch)
        if hasattr(model, "get_text_features"):
            vector = model.get_text_features(**inputs)
        else:
            output = model(**inputs)
            vector = getattr(output, "text_embeds", None)
            if vector is None:
                vector = getattr(output, "pooler_output", None)
            if vector is None:
                raise RuntimeError("SigLIP2 runtime exposed no text embedding")
    values = _normalize_tensor(vector)
    return {"model": model_id, "space": f"{model_id}-joint", "dim": len(values), "vector": values}


def _siglip_image_batch(request: dict, model_id: str) -> dict:
    raw_items = request.get("items")
    if not isinstance(raw_items, list) or not 1 <= len(raw_items) <= MAX_BATCH_IMAGES:
        raise ValueError(f"items must contain 1..{MAX_BATCH_IMAGES} batch entries")
    ids: list[str] = []
    images = []
    total_raw_bytes = 0
    seen_ids: set[str] = set()
    for item in raw_items:
        if not isinstance(item, dict):
            raise ValueError("each batch entry must be an object")
        item_id = item.get("id")
        if not isinstance(item_id, str) or not item_id or len(item_id) > 128:
            raise ValueError("batch ids must be non-empty strings up to 128 characters")
        if item_id in seen_ids:
            raise ValueError("batch ids must be unique")
        seen_ids.add(item_id)
        raw, image = _decode_image(str(item.get("data_b64", "")))
        total_raw_bytes += len(raw)
        if total_raw_bytes > MAX_BATCH_RAW_BYTES:
            raise ValueError("batch decoded image bytes exceed the 64 MiB aggregate ceiling")
        ids.append(item_id)
        images.append(image)

    rows = _siglip_images(images, model_id)
    return {
        "model": model_id,
        "space": f"{model_id}-joint",
        "count": len(rows),
        "items": [
            {"id": item_id, "dim": len(values), "vector": values}
            for item_id, values in zip(ids, rows)
        ],
    }


def _load_dino():
    key = "dinov3-vitb16-lvd1689m"
    if key in _CACHE:
        return _CACHE[key]
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    _prepare_for_model(key)
    import torch
    from transformers import AutoImageProcessor, AutoModel
    path = str(_model_dir(key))
    processor = AutoImageProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    target, load_kwargs = _warm_encoder_load_kwargs(torch)
    model = AutoModel.from_pretrained(
        path, local_files_only=True, trust_remote_code=False, **load_kwargs)
    if target == "mps":
        model = model.to("mps")
    model.eval()
    _CACHE[key] = (model, processor)
    return model, processor


def _dino_image(image) -> dict:
    import torch
    model, processor = _load_dino()
    with torch.inference_mode():
        inputs = _move_encoder_inputs(
            processor(images=image, return_tensors="pt"), model, torch)
        output = model(**inputs)
        vector = getattr(output, "pooler_output", None)
        if vector is None:
            hidden = getattr(output, "last_hidden_state", None)
            if hidden is None:
                raise RuntimeError("DINOv3 runtime exposed no embedding")
            vector = hidden[:, 0]
    values = _normalize_tensor(vector)
    return {"model": "dinov3-vitb16-lvd1689m", "space": "dinov3-visual", "dim": len(values), "vector": values}


def _paddle_ocr(raw: bytes, suffix: str = ".png") -> dict:
    key = "paddleocr-vl-1.6"
    if reason := unsupported_reason(key):
        raise RuntimeError(reason)
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    _prepare_for_model(key)
    from paddleocr import PaddleOCRVL
    pipeline = _CACHE.get(key)
    if pipeline is None:
        pipeline = PaddleOCRVL(
            pipeline_version="v1.6",
            vl_rec_model_dir=str(_model_dir(key)),
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_layout_detection=False,
        )
        _CACHE[key] = pipeline
    suffix = suffix if re.fullmatch(r"\.[A-Za-z0-9]{1,8}", suffix or "") else ".bin"
    with tempfile.TemporaryDirectory(prefix="private-librarian-ocr-") as directory:
        path = Path(directory) / ("input" + suffix)
        path.write_bytes(raw)
        result = pipeline.predict(str(path))
        pieces = []
        for item in result if isinstance(result, (list, tuple)) else [result]:
            if hasattr(item, "json"):
                try:
                    item = json.loads(item.json)
                except Exception:
                    pass
            if isinstance(item, dict):
                for field in ("text", "rec_text", "markdown", "content"):
                    value = item.get(field)
                    if isinstance(value, str) and value.strip():
                        pieces.append(value.strip())
                for field in ("rec_texts", "texts"):
                    value = item.get(field)
                    if isinstance(value, list):
                        pieces.extend(str(v).strip() for v in value if str(v).strip())
            elif isinstance(item, str) and item.strip():
                pieces.append(item.strip())
        text = "\n".join(pieces).strip()[:200_000]
        return {"model": key, "text": text, "confidence": 0.85 if text else 0.0}


def _classification_prompt(existing: dict) -> str:
    allowed = ", ".join(sorted(ALLOWED_CATEGORIES))
    return (
        "You classify one local file for a coarse file organizer. Do not invent folders. "
        "Return JSON only with keys categories (array), description (short string), confidence (0..1), "
        "reasons (short array). Choose categories only from this allowlist: " + allowed + ". "
        "Prefer fewer broad categories. If unsure use Review. Existing deterministic evidence follows:\n" +
        json.dumps(existing, ensure_ascii=False)[:MAX_TEXT_CHARS]
    )


def _extract_json(text: str) -> dict:
    text = text.strip()[:MAX_OUTPUT_CHARS]
    try:
        obj = json.loads(text)
    except Exception:
        start, end = text.find("{"), text.rfind("}")
        if start < 0 or end <= start:
            raise ValueError("model response contained no JSON object")
        obj = json.loads(text[start:end + 1])
    if not isinstance(obj, dict):
        raise ValueError("classification output must be an object")
    raw_categories = obj.get("categories", [])
    if not isinstance(raw_categories, list):
        raise ValueError("categories must be an array")
    categories = []
    for value in raw_categories[:6]:
        category = str(value).strip()
        if category not in ALLOWED_CATEGORIES:
            raise ValueError(f"non-canonical category rejected: {category!r}")
        if category not in categories:
            categories.append(category)
    if not categories:
        categories = ["Review"]
    confidence = float(obj.get("confidence", 0.0))
    if not math.isfinite(confidence):
        confidence = 0.0
    confidence = max(0.0, min(1.0, confidence))
    description = str(obj.get("description", ""))[:512]
    raw_reasons = obj.get("reasons", [])
    reasons = [str(value)[:96] for value in raw_reasons[:8]] if isinstance(raw_reasons, list) else []
    return {"categories": categories, "description": description, "confidence": confidence, "reasons": reasons}


def _vlm_classify(model_id: str, image, existing: dict) -> dict:
    if not _verify_snapshot(model_id):
        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")
    _prepare_for_model(model_id)
    prompt = _classification_prompt(existing)
    path = str(_model_dir(model_id))
    if model_id == "minicpm-v-4.6":
        from transformers import AutoModel, AutoTokenizer
        cached = _CACHE.get(model_id)
        if cached is None:
            tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=True)
            model = AutoModel.from_pretrained(
                path, local_files_only=True, trust_remote_code=True,
                **_large_model_load_kwargs(model_id))
            model.eval()
            cached = (model, tokenizer)
            _CACHE[model_id] = cached
        model, tokenizer = cached
        response = model.chat(image=image, msgs=[{"role": "user", "content": prompt}], tokenizer=tokenizer,
                              sampling=False, temperature=0)
        return _extract_json(response[0] if isinstance(response, tuple) else str(response))
    from transformers import AutoModelForImageTextToText, AutoProcessor
    cached = _CACHE.get(model_id)
    if cached is None:
        trust = model_id == "lfm2.5-vl-3b"
        processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=trust)
        model = AutoModelForImageTextToText.from_pretrained(
            path, local_files_only=True, trust_remote_code=trust,
            **_large_model_load_kwargs(model_id))
        model.eval()
        cached = (model, processor)
        _CACHE[model_id] = cached
    model, processor = cached
    conversation = [{"role": "user", "content": [{"type": "image"}, {"type": "text", "text": prompt}]}]
    formatted = processor.apply_chat_template(conversation, add_generation_prompt=True, tokenize=False)
    inputs = processor(text=[formatted], images=[image], return_tensors="pt")
    device = getattr(model, "device", None)
    if device is not None:
        inputs = {k: v.to(device) if hasattr(v, "to") else v for k, v in inputs.items()}
    output = model.generate(**inputs, do_sample=False, max_new_tokens=320)
    input_len = inputs["input_ids"].shape[-1] if "input_ids" in inputs else 0
    text = processor.batch_decode(output[:, input_len:], skip_special_tokens=True)[0]
    return _extract_json(text)


def _release(model_id: str | None) -> dict:
    if model_id:
        _CACHE.pop(model_id, None)
        _TRUSTED.discard(model_id)
        _TRUSTED_ROOTS.pop(model_id, None)
        _remove_offload(model_id)
        _clear_accelerator_cache()
    else:
        _drop_cached_models()
    return {"released": model_id or "all", "resident": sorted(_CACHE)}


def _accelerator_memory_status() -> dict:
    """Report allocator/driver memory without changing cache residency.

    On MPS, ``current_allocated_bytes`` is tensor storage only, while
    ``driver_allocated_bytes`` also includes allocator pools and MPSGraph/Metal
    allocations. Keep these distinct rather than pretending either is total
    unified memory.
    """
    result = {"backend": "cpu", "mps_available": False, "resident": sorted(_CACHE)}
    try:
        import torch
        mps = getattr(torch, "mps", None)
        backend = getattr(getattr(torch, "backends", None), "mps", None)
        available = bool(mps is not None and backend is not None and backend.is_available())
        result["mps_available"] = available
        if not available:
            return result
        result["backend"] = "mps"
        for key, name in (
            ("current_allocated_bytes", "current_allocated_memory"),
            ("driver_allocated_bytes", "driver_allocated_memory"),
            ("recommended_max_bytes", "recommended_max_memory"),
        ):
            getter = getattr(mps, name, None)
            if not callable(getter):
                continue
            try:
                result[key] = int(getter())
            except Exception as exc:
                result[key + "_error"] = str(exc)[:160]
    except Exception as exc:
        result["error"] = str(exc)[:160]
    return result


def _handle(request: dict) -> dict:
    op = request.get("op")
    if op == "status":
        ids = request.get("models") or list(MODEL_SPECS)
        return {
            "offline": True,
            "available": {mid: _verify_snapshot(mid, verify_hashes=False) for mid in ids if mid in MODEL_SPECS},
            "resident": sorted(_CACHE),
            "memory_policy": "11.50-GB-ceiling; warm-encoders-only; transient-exclusive; MPS-fp16",
        }
    if op == "memory":
        return _accelerator_memory_status()
    if op == "release":
        model_id = request.get("model")
        return _release(str(model_id) if model_id else None)
    if op == "siglip_image":
        model_id = str(request.get("model", "siglip2-so400m-naflex"))
        if model_id not in SIGLIP_MODELS:
            raise ValueError("model is not a configured SigLIP encoder")
        _, image = _decode_image(str(request.get("data_b64", "")))
        return _siglip_image(image, model_id)
    if op == "siglip_image_batch":
        model_id = str(request.get("model", "siglip2-so400m-naflex"))
        if model_id not in SIGLIP_MODELS:
            raise ValueError("model is not a configured SigLIP encoder")
        return _siglip_image_batch(request, model_id)
    if op == "siglip_text":
        model_id = str(request.get("model", "siglip2-so400m-naflex"))
        if model_id not in SIGLIP_MODELS:
            raise ValueError("model is not a configured SigLIP encoder")
        return _siglip_text(str(request.get("text", ""))[:MAX_TEXT_CHARS], model_id)
    if op == "dino_image":
        _, image = _decode_image(str(request.get("data_b64", "")))
        return _dino_image(image)
    if op == "ocr":
        raw, _ = _decode_image(str(request.get("data_b64", "")))
        return _paddle_ocr(raw, str(request.get("suffix", ".png")))
    if op == "classify_image":
        model_id = str(request.get("model", "minicpm-v-4.6"))
        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b"}:
            raise ValueError("model is not a configured VLM fallback")
        _, image = _decode_image(str(request.get("data_b64", "")))
        evidence = request.get("evidence") if isinstance(request.get("evidence"), dict) else {}
        return _vlm_classify(model_id, image, evidence)
    raise ValueError(f"unknown operation {op!r}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--worker", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--syntax-check", action="store_true")
    parser.add_argument("--runtime-check", choices=sorted(MODEL_SPECS))
    args = parser.parse_args()
    if args.syntax_check:
        _memory_policy_self_test()
        print(json.dumps({
            "status": "ok",
            "offline": True,
            "models": sorted(MODEL_SPECS),
            "memory_policy": "11.50-GB-ceiling; warm-encoders-only; transient-exclusive; MPS-fp16",
            "warm_encoder_backend": "mps-fp16-when-available; cpu-fp32-fallback",
            "semantic_encoder_policy": "profile-exclusive-base-or-so400m",
            "max_siglip_benchmark_batch": MAX_BATCH_IMAGES,
            "max_siglip_benchmark_raw_bytes": MAX_BATCH_RAW_BYTES,
        }))
        return 0
    if args.runtime_check:
        ready, reason = runtime_check(args.runtime_check)
        print(json.dumps({"offline": True, "model": args.runtime_check,
                          "available": ready, "reason": reason}))
        return 0 if ready else 1
    if args.check:
        print(json.dumps({"offline": True, "available": {mid: _verify_snapshot(mid, verify_hashes=False) for mid in MODEL_SPECS}}))
        return 0
    if not args.worker:
        parser.error("use --worker, --check, or --syntax-check")
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError("request must be an object")
            response = _handle(request)
        except Exception as exc:
            response = {"error": str(exc)[:512]}
        encoded = json.dumps(response, separators=(",", ":"), ensure_ascii=False)
        print(encoded[:2_000_000], flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
