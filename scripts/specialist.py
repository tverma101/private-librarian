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

MODEL_SPECS = {
    "siglip2-so400m-naflex": ("google/siglip2-so400m-patch16-naflex", "cc24074"),
    "dinov3-vitb16-lvd1689m": ("facebook/dinov3-vitb16-pretrain-lvd1689m", "5931719"),
    "paddleocr-vl-1.6": ("PaddlePaddle/PaddleOCR-VL-1.6", "cdc88f5"),
    "minicpm-v-4.6": ("openbmb/MiniCPM-V-4.6", "8169864"),
    "lfm2.5-vl-3b": ("LiquidAI/LFM2.5-VL-3B", "5a414ea"),
}

RUNTIME_MODULES = {
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
WARM_MODELS = {
    "siglip2-so400m-naflex",
    "dinov3-vitb16-lvd1689m",
}
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
    # Warm embedding models may coexist with one another, but never with a leaked transient model.
    leaked = set(_CACHE) - WARM_MODELS
    if leaked:
        _drop_cached_models(keep=set(_CACHE) & WARM_MODELS)


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
    # Dependency-free invariant test used by CI. Dummy objects prove transient escalation evicts
    # warm encoders, while warm-to-warm transitions are allowed to retain both encoders.
    _CACHE.clear()
    _CACHE["siglip2-so400m-naflex"] = object()
    _CACHE["dinov3-vitb16-lvd1689m"] = object()
    _prepare_for_model("minicpm-v-4.6")
    if _CACHE:
        raise RuntimeError("transient model did not evict warm model cache")
    _CACHE["siglip2-so400m-naflex"] = object()
    _prepare_for_model("dinov3-vitb16-lvd1689m")
    if set(_CACHE) != {"siglip2-so400m-naflex"}:
        raise RuntimeError("warm model policy evicted compatible encoder")
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


def _normalize_tensor(vector) -> list[float]:
    if hasattr(vector, "detach"):
        vector = vector.detach()
    if getattr(vector, "ndim", 1) > 1:
        vector = vector[0]
    vector = vector.float().cpu()
    norm = float(vector.norm(p=2))
    if not math.isfinite(norm) or norm <= 0:
        raise ValueError("non-finite/zero embedding")
    values = (vector / norm).tolist()
    if not values or any(not math.isfinite(float(v)) for v in values):
        raise ValueError("invalid embedding values")
    return [float(v) for v in values]


def _load_siglip():
    key = "siglip2-so400m-naflex"
    if key in _CACHE:
        return _CACHE[key]
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    _prepare_for_model(key)
    from transformers import AutoModel, AutoProcessor
    path = str(_model_dir(key))
    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(
        path, local_files_only=True, trust_remote_code=False, low_cpu_mem_usage=True)
    model.eval()
    _CACHE[key] = (model, processor)
    return model, processor


def _siglip_image(image) -> dict:
    import torch
    model, processor = _load_siglip()
    with torch.inference_mode():
        inputs = processor(images=image, return_tensors="pt")
        if hasattr(model, "get_image_features"):
            vector = model.get_image_features(**inputs)
        else:
            output = model(**inputs)
            vector = getattr(output, "image_embeds", None)
            if vector is None:
                vector = getattr(output, "pooler_output", None)
            if vector is None:
                raise RuntimeError("SigLIP2 runtime exposed no image embedding")
    values = _normalize_tensor(vector)
    return {"model": "siglip2-so400m-naflex", "space": "siglip2-joint", "dim": len(values), "vector": values}


def _siglip_text(text: str) -> dict:
    import torch
    model, processor = _load_siglip()
    with torch.inference_mode():
        inputs = processor(text=[text[:MAX_TEXT_CHARS]], padding="max_length", return_tensors="pt")
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
    return {"model": "siglip2-so400m-naflex", "space": "siglip2-joint", "dim": len(values), "vector": values}


def _load_dino():
    key = "dinov3-vitb16-lvd1689m"
    if key in _CACHE:
        return _CACHE[key]
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    _prepare_for_model(key)
    from transformers import AutoImageProcessor, AutoModel
    path = str(_model_dir(key))
    processor = AutoImageProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(
        path, local_files_only=True, trust_remote_code=False, low_cpu_mem_usage=True)
    model.eval()
    _CACHE[key] = (model, processor)
    return model, processor


def _dino_image(image) -> dict:
    import torch
    model, processor = _load_dino()
    with torch.inference_mode():
        output = model(**processor(images=image, return_tensors="pt"))
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
    if op == "release":
        model_id = request.get("model")
        return _release(str(model_id) if model_id else None)
    if op == "siglip_image":
        _, image = _decode_image(str(request.get("data_b64", "")))
        return _siglip_image(image)
    if op == "siglip_text":
        return _siglip_text(str(request.get("text", ""))[:MAX_TEXT_CHARS])
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
