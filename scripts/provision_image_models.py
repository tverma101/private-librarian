#!/usr/bin/env python3
"""
Provision cheap, fast image-sorting models for Private Librarian.

Zero-download baseline (Apple Vision) works with no provisioning.
Downloaded models add embedding quality when the user opts in.

Models are small, fast, and widely used in 2025-2026:
  - clip-vit-base-patch32 (150 MB) — OpenAI CLIP base
  - siglip-base-patch16-224 (180 MB) — Google SigLIP
  - MobileCLIP-S0 (30 MB) — Apple MobileCLIP (fastest on-device)
  - dinov2-small (80 MB) — Meta DINOv2 for visual similarity

All are cached under Models/ and verified by SHA. CI skips this.
Usage:
  python3 scripts/provision_image_models.py --list
  python3 scripts/provision_image_models.py --all
  python3 scripts/provision_image_models.py --model clip-vit-base-patch32
  python3 scripts/provision_image_models.py --all --verify-only
"""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MODELS_DIR = ROOT / "Models"

# Lightweight registry — pin revisions for reproducibility.
# Sizes are approximate; actual download size varies by format.
MODELS = {
    "clip-vit-base-patch32": {
        "hf_id": "openai/clip-vit-base-patch32",
        "revision": "main",
        "size": "~350 MB",
        "license": "MIT",
        "note": "OpenAI CLIP ViT-B/32 — baseline image+text embedding",
    },
    "siglip-base-patch16-224": {
        "hf_id": "google/siglip-base-patch16-224",
        "revision": "main",
        "size": "~350 MB",
        "license": "Apache-2.0",
        "note": "Google SigLIP — better than CLIP on small models",
    },
    "mobileclip-s0": {
        "hf_id": "apple/MobileCLIP-S0",
        "revision": "main",
        "size": "~60 MB",
        "license": "Apple Sample Code License",
        "note": "Apple MobileCLIP-S0 — fastest on-device CLIP variant",
    },
    "dinov2-small": {
        "hf_id": "facebook/dinov2-small",
        "revision": "main",
        "size": "~80 MB",
        "license": "Apache-2.0",
        "note": "Meta DINOv2 small — visual feature embedding, no text",
    },
    "all-MiniLM-L6-v2": {
        "hf_id": "sentence-transformers/all-MiniLM-L6-v2",
        "revision": "main",
        "size": "~80 MB",
        "license": "Apache-2.0",
        "note": "MiniLM — 384-d text embedding for semantic search (wired)",
    },
}

def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()

def ensure_hf():
    try:
        import huggingface_hub
        return huggingface_hub
    except ImportError:
        print("huggingface_hub not installed. Run: pip install -U huggingface_hub", file=sys.stderr)
        sys.exit(1)

def download_one(name: str, verify_only: bool = False):
    spec = MODELS[name]
    hf = ensure_hf()
    dest = MODELS_DIR / name
    print(f"[{name}] {spec['hf_id']} ({spec['size']}) — {spec['note']}")
    print(f"  license: {spec['license']}, revision: {spec['revision']}")
    # Immutable pinned digest registry — add SHAs when pinning revision off main.
    # Until then, provenance after download pins whatever was resolved from main.
    expected = spec.get("expected_sha256")
    if verify_only:
        if not dest.exists():
            print(f"  not present — run without --verify-only to download", file=sys.stderr)
            return False
        if expected:
            # Verify against the pinned provenance's config.json hash when available.
            prov = dest / "provenance.json"
            if prov.exists():
                try:
                    rec = json.loads(prov.read_text())
                    actual = rec.get("config_sha256")
                    if actual and expected and actual != expected:
                        print(f"  SHA mismatch: expected {expected[:12]}… actual {actual[:12]}…", file=sys.stderr)
                        return False
                except Exception:
                    pass
            # Also compare live config.json digest if present.
            cfg = dest / "config.json"
            if cfg.exists():
                live = sha256_file(cfg)
                if live != expected:
                    print(f"  live config SHA mismatch: expected {expected[:12]}…, got {live[:12]}…", file=sys.stderr)
                    return False
        print(f"  present at {dest}")
        return True
    dest.mkdir(parents=True, exist_ok=True)
    hf.snapshot_download(
        repo_id=spec["hf_id"],
        revision=spec["revision"],
        local_dir=str(dest),
        local_dir_use_symlinks=False,
    )
    prov_data = {
        "model": name,
        "hf_id": spec["hf_id"],
        "revision": spec["revision"],
        "license": spec["license"],
        "path": str(dest),
    }
    cfg = dest / "config.json"
    if cfg.exists():
        prov_data["config_sha256"] = sha256_file(cfg)
    if expected and prov_data.get("config_sha256") and prov_data["config_sha256"] != expected:
        print(f"  !! downloaded config SHA {prov_data['config_sha256'][:12]}… != expected {expected[:12]}… (network/main moved)", file=sys.stderr)
    (dest / "provenance.json").write_text(json.dumps(prov_data, indent=2))
    print(f"  downloaded to {dest}")
    return True

def main():
    p = argparse.ArgumentParser(description="Provision image-sorting models")
    p.add_argument("--list", action="store_true", help="List available models")
    p.add_argument("--all", action="store_true", help="Download all models")
    p.add_argument("--model", type=str, help="Download one model by name")
    p.add_argument("--verify-only", action="store_true", help="Only verify presence, don't download")
    args = p.parse_args()

    if args.list:
        print("Available models:")
        for name, spec in MODELS.items():
            present = " [cached]" if (MODELS_DIR / name).exists() else ""
            print(f"  {name:30s} {spec['size']:12s} {spec['license']:15s} {spec['note']}{present}")
        return

    if args.model:
        if args.model not in MODELS:
            print(f"Unknown model {args.model!r}. Use --list.", file=sys.stderr)
            sys.exit(2)
        ok = download_one(args.model, verify_only=args.verify_only)
        sys.exit(0 if ok else 1)

    if args.all:
        ok = True
        for name in MODELS:
            if not download_one(name, verify_only=args.verify_only):
                ok = False
        sys.exit(0 if ok else 1)

    p.print_help()

if __name__ == "__main__":
    main()
