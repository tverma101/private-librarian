#!/usr/bin/env python3
"""
Offline local embedding helper — no network, no telemetry.

Uses downloaded HF checkpoints under Models/ via local_files_only=True.
Called by LibrarianCore/LocalModelBridge.swift as a subprocess.

Usage:
  python3 scripts/embed.py --image /path/to/photo.jpg --model clip-vit-base-patch32
  python3 scripts/embed.py --text "cats on a beach" --model all-MiniLM-L6-v2
  python3 scripts/embed.py --check  # exit 0 if runtime available, non-zero otherwise
  python3 scripts/embed.py --batch-images /path/list.txt  # one path per line, JSONL output

Output: JSON to stdout {"dim":512,"vector":[0.1, ...]} or {"error":"..."}.
Never touches the network — verified by entitlement-audit and network_negative_probe.
"""

import argparse
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "Models"

# Map logical model name -> HF dir + runtime
# clip-vit-base-patch32: CLIP image + text (PyTorch, PIL processor fallback — no torchvision needed)
# all-MiniLM-L6-v2: text embedding via sentence_transformers
MODEL_HANDLERS = {
    "clip-vit-base-patch32": "clip",
    "all-MiniLM-L6-v2": "minilm",
}

# Lazy singletons — keep model warm within one process invocation (batch mode)
_clip_model = None
_clip_proc = None
_minilm_model = None


def _check_deps():
    try:
        import torch  # noqa: F401
        import transformers  # noqa: F401
        from PIL import Image  # noqa: F401
    except ImportError as e:
        print(json.dumps({"error": f"missing dependency: {e}"}))
        return False
    return True


def _load_clip():
    global _clip_model, _clip_proc
    if _clip_model is not None:
        return _clip_model, _clip_proc
    from transformers import CLIPImageProcessor, CLIPModel

    # CLIPImageProcessor needs no torchvision — falls back to PIL path
    _clip_proc = CLIPImageProcessor.from_pretrained(
        str(MODELS_DIR / "clip-vit-base-patch32"), local_files_only=True
    )
    _clip_model = CLIPModel.from_pretrained(
        str(MODELS_DIR / "clip-vit-base-patch32"), local_files_only=True
    )
    _clip_model.eval()
    return _clip_model, _clip_proc


def _load_minilm():
    global _minilm_model
    if _minilm_model is not None:
        return _minilm_model
    from sentence_transformers import SentenceTransformer

    _minilm_model = SentenceTransformer(
        str(MODELS_DIR / "all-MiniLM-L6-v2"), device="cpu", trust_remote_code=False
    )
    return _minilm_model


def embed_image(path: str, model: str = "clip-vit-base-patch32"):
    if model != "clip-vit-base-patch32":
        return {"error": f"unknown image model {model!r}"}
    p = Path(path)
    if not p.exists():
        return {"error": f"not found: {path}"}
    dest = MODELS_DIR / model
    if not (dest / "config.json").exists():
        return {"error": f"model not provisioned: {model} — run provision_image_models.py --model {model}"}
    try:
        import torch
        from PIL import Image

        clip_model, clip_proc = _load_clip()
        # Use SourceBroker boundedRead semantics: open via PIL, handles truncated gracefully
        try:
            img = Image.open(path).convert("RGB")
        except Exception as e:
            return {"error": f"cannot open image: {e}"}
        with torch.no_grad():
            inputs = clip_proc(images=img, return_tensors="pt")
            # transformers 5.x returns BaseModelOutputWithPooling — pooler_output is the embedding
            out = clip_model.get_image_features(pixel_values=inputs["pixel_values"])
            # Handle both Tensor and wrapper return shapes
            if hasattr(out, "pooler_output"):
                vec = out.pooler_output[0]
            elif hasattr(out, "image_embeds"):
                vec = out.image_embeds[0]
            else:
                vec = out[0] if len(out.shape) == 2 else out
            # L2-normalize for cosine search
            vec = vec / vec.norm(p=2).clamp(min=1e-9)
            arr = vec.cpu().tolist()
            return {"dim": len(arr), "vector": arr, "model": model}
    except Exception as e:
        return {"error": f"clip inference failed: {e}"}


def embed_text(text: str, model: str = "all-MiniLM-L6-v2"):
    if model != "all-MiniLM-L6-v2":
        return {"error": f"unknown text model {model!r}"}
    dest = MODELS_DIR / model
    if not (dest / "config.json").exists():
        return {"error": f"model not provisioned: {model} — run provision_image_models.py --model {model}"}
    if not text or not text.strip():
        return {"error": "empty text"}
    try:
        mdl = _load_minilm()
        # sentence_transformers handles tokenization + pooling internally, already normalized if configured
        vec = mdl.encode(text.strip()[:4000], convert_to_tensor=False, normalize_embeddings=True)
        arr = vec.tolist() if hasattr(vec, "tolist") else list(vec)
        return {"dim": len(arr), "vector": arr, "model": model}
    except Exception as e:
        return {"error": f"minilm inference failed: {e}"}


def main():
    ap = argparse.ArgumentParser(description="Offline embedding helper (no network)")
    ap.add_argument("--image", type=str, help="Image path to embed")
    ap.add_argument("--text", type=str, help="Text to embed")
    ap.add_argument("--model", type=str, default=None, help="Model name (default: clip for --image, minilm for --text)")
    ap.add_argument("--batch-images", type=str, help="File with one image path per line; outputs JSONL")
    ap.add_argument("--check", action="store_true", help="Check runtime deps and exit 0/1")
    args = ap.parse_args()

    if args.check:
        ok = _check_deps()
        # Also verify at least one model is provisioned
        any_model = any((MODELS_DIR / m / "config.json").exists() for m in MODEL_HANDLERS)
        if not any_model:
            print(json.dumps({"error": "no models provisioned under Models/"}), file=sys.stderr)
            sys.exit(2)
        sys.exit(0 if ok else 1)

    if args.batch_images:
        model = args.model or "clip-vit-base-patch32"
        try:
            paths = Path(args.batch_images).read_text().splitlines()
        except Exception as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)
        for p in paths:
            p = p.strip()
            if not p:
                continue
            res = embed_image(p, model=model)
            print(json.dumps(res))
        return

    if args.image:
        model = args.model or "clip-vit-base-patch32"
        res = embed_image(args.image, model=model)
        print(json.dumps(res))
        sys.exit(0 if "vector" in res else 1)

    if args.text is not None:
        model = args.model or "all-MiniLM-L6-v2"
        res = embed_text(args.text, model=model)
        print(json.dumps(res))
        sys.exit(0 if "vector" in res else 1)

    ap.print_help()
    sys.exit(2)


if __name__ == "__main__":
    main()
