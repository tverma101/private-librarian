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
import hashlib
import io
import json
import math
import os
import re
import sys
import tempfile
from pathlib import Path

# Set offline policy BEFORE importing transformers/paddle/etc.
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_DATASETS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("DO_NOT_TRACK", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

ROOT = Path(__file__).resolve().parent.parent
MODELS_ROOT = Path(os.environ.get("LIBRARIAN_SPECIALIST_MODELS_DIR", ROOT / "Models" / "specialists"))
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_TEXT_CHARS = 16_000
MAX_OUTPUT_CHARS = 8_192

MODEL_SPECS = {
    "siglip2-so400m-naflex": ("google/siglip2-so400m-patch16-naflex", "cc24074"),
    "dinov3-vitb16-lvd1689m": ("facebook/dinov3-vitb16-pretrain-lvd1689m", "5931719"),
    "paddleocr-vl-1.6": ("PaddlePaddle/PaddleOCR-VL-1.6", "cdc88f5"),
    "minicpm-v-4.6": ("openbmb/MiniCPM-V-4.6", "8169864"),
    "ling-3.0-tiny": ("inclusionAI/Ling-3.0-tiny", "b61f433"),
    "lfm2.5-vl-3b": ("LiquidAI/LFM2.5-VL-3B", "5a414ea"),
    "internvl3.5-4b": ("OpenGVLab/InternVL3_5-4B", "481f6e3"),
    "mimo-vl-7b-rl-2508": ("XiaomiMiMo/MiMo-VL-7B-RL-2508", "4bfb270"),
}

# A generative model may choose among existing broad product concepts only.
# Course IDs and project names remain deterministic/catalog-derived, never hallucinated here.
ALLOWED_CATEGORIES = {
    "Image", "Image/Animals", "Image/Vehicles", "Image/Scenery", "Image/Food", "Image/Documents",
    "Screenshots", "Screenshots/code", "Screenshots/school", "Screenshots/lms", "Screenshots/receipt",
    "Screenshots/error", "Screenshots/conversation", "Screenshots/social", "Screenshots/map",
    "Screenshots/meme", "Screenshots/reference", "School", "Projects/Code", "Documents/PDF",
    "Documents/Text", "Documents/Office", "Archives", "DiskImages", "Applications", "Packages", "Review",
}

_CACHE = {}
_TRUSTED = set()


def _sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _model_dir(model_id: str) -> Path:
    if model_id not in MODEL_SPECS:
        raise ValueError(f"unknown specialist model {model_id!r}")
    return MODELS_ROOT / model_id


def _verify_snapshot(model_id: str, verify_hashes: bool = True) -> bool:
    if model_id in _TRUSTED:
        return True
    hf_id, revision_prefix = MODEL_SPECS.get(model_id, (None, None))
    if not hf_id:
        return False
    root = _model_dir(model_id)
    try:
        record = json.loads((root / "provenance.json").read_text())
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
        if not isinstance(relative, str) or not isinstance(wanted, str) or len(wanted) != 64:
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
    _TRUSTED.add(model_id)
    return True


def _decode_image(value: str):
    raw = base64.b64decode(value, validate=True)
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("image payload is empty or exceeds the 64 MiB specialist ceiling")
    from PIL import Image
    image = Image.open(io.BytesIO(raw)).convert("RGB")
    image.load()
    return raw, image


def _normalize_tensor(vector) -> list[float]:
    # torch is imported lazily by model operations.
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
    from transformers import AutoModel, AutoProcessor
    path = str(_model_dir(key))
    processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=False)
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
            vector = getattr(output, "image_embeds", None) or getattr(output, "pooler_output", None)
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
            vector = getattr(output, "text_embeds", None) or getattr(output, "pooler_output", None)
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
    from transformers import AutoImageProcessor, AutoModel
    path = str(_model_dir(key))
    processor = AutoImageProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=False)
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
    if not _verify_snapshot(key):
        raise RuntimeError(f"untrusted/unprovisioned model: {key}")
    # PaddleOCR-VL currently exposes a path-oriented pipeline. We therefore write
    # broker-owned bytes to a private temporary file; the source path is never forwarded.
    from paddleocr import PaddleOCRVL
    pipeline = _CACHE.get(key)
    if pipeline is None:
        pipeline = PaddleOCRVL(vl_rec_model_dir=str(_model_dir(key)))
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


def _load_text_generator(model_id: str):
    if model_id in _CACHE:
        return _CACHE[model_id]
    if not _verify_snapshot(model_id):
        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")
    from transformers import AutoModelForCausalLM, AutoTokenizer
    path = str(_model_dir(model_id))
    tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)
    model = AutoModelForCausalLM.from_pretrained(path, local_files_only=True, trust_remote_code=False, device_map="auto")
    model.eval()
    _CACHE[model_id] = (model, tokenizer)
    return model, tokenizer


def _ling_classify(existing: dict) -> dict:
    import torch
    model, tokenizer = _load_text_generator("ling-3.0-tiny")
    prompt = _classification_prompt(existing)
    encoded = tokenizer(prompt, return_tensors="pt", truncation=True, max_length=4096)
    device = getattr(model, "device", None)
    if device is not None:
        encoded = {k: v.to(device) for k, v in encoded.items()}
    with torch.inference_mode():
        output = model.generate(**encoded, do_sample=False, max_new_tokens=320)
    generated = output[0][encoded["input_ids"].shape[-1]:]
    return _extract_json(tokenizer.decode(generated, skip_special_tokens=True))


def _vlm_classify(model_id: str, image, existing: dict) -> dict:
    if not _verify_snapshot(model_id):
        raise RuntimeError(f"untrusted/unprovisioned model: {model_id}")
    prompt = _classification_prompt(existing)
    path = str(_model_dir(model_id))

    # MiniCPM and InternVL expose model-specific chat() APIs. Custom code is allowed
    # only from this already hash-verified, immutable local snapshot.
    if model_id in {"minicpm-v-4.6", "internvl3.5-4b"}:
        from transformers import AutoModel, AutoTokenizer
        cached = _CACHE.get(model_id)
        if cached is None:
            tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=True)
            model = AutoModel.from_pretrained(path, local_files_only=True, trust_remote_code=True, device_map="auto")
            model.eval()
            cached = (model, tokenizer)
            _CACHE[model_id] = cached
        model, tokenizer = cached
        if model_id == "minicpm-v-4.6":
            response = model.chat(image=image, msgs=[{"role": "user", "content": prompt}], tokenizer=tokenizer,
                                  sampling=False, temperature=0)
        else:
            response = model.chat(tokenizer, image, prompt, generation_config={"do_sample": False, "max_new_tokens": 320})
        return _extract_json(response[0] if isinstance(response, tuple) else str(response))

    # MiMo/LFM follow the standard processor + image-text-generation path on current Transformers.
    from transformers import AutoModelForImageTextToText, AutoProcessor
    cached = _CACHE.get(model_id)
    if cached is None:
        trust = model_id == "lfm2.5-vl-3b"
        processor = AutoProcessor.from_pretrained(path, local_files_only=True, trust_remote_code=trust)
        model = AutoModelForImageTextToText.from_pretrained(
            path, local_files_only=True, trust_remote_code=trust, device_map="auto")
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


def _handle(request: dict) -> dict:
    op = request.get("op")
    if op == "status":
        ids = request.get("models") or list(MODEL_SPECS)
        return {"offline": True, "available": {mid: _verify_snapshot(mid, verify_hashes=False) for mid in ids if mid in MODEL_SPECS}}
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
    if op == "classify_text":
        return _ling_classify(request.get("evidence") if isinstance(request.get("evidence"), dict) else {})
    if op == "classify_image":
        model_id = str(request.get("model", "minicpm-v-4.6"))
        if model_id not in {"minicpm-v-4.6", "lfm2.5-vl-3b", "internvl3.5-4b", "mimo-vl-7b-rl-2508"}:
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
    args = parser.parse_args()
    if args.syntax_check:
        print(json.dumps({"status": "ok", "offline": True, "models": sorted(MODEL_SPECS)}))
        return 0
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
