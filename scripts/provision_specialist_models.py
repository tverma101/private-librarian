#!/usr/bin/env python3
"""Provision the final local specialist stack with immutable provenance.

The app never calls this script automatically. Downloads are an explicit operator action.
Runtime inference is offline-only; this provisioner is the only component that needs network.

Examples:
  python3 scripts/provision_specialist_models.py --list
  python3 scripts/provision_specialist_models.py --profile embeddings
  python3 scripts/provision_specialist_models.py --profile balanced
  python3 scripts/provision_specialist_models.py --model minicpm-v-4.6
  python3 scripts/provision_specialist_models.py --profile balanced --verify-only

`quality` intentionally includes very large models and must be explicitly requested.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parent.parent
MODELS_ROOT = Path(os.environ.get("LIBRARIAN_SPECIALIST_MODELS_DIR", ROOT / "Models" / "specialists"))

# Keep this table in lock-step with Sources/LibrarianCore/LocalModelRouter.swift.
# revision_prefix is an immutable commit prefix verified against the Hub before download.
MODELS = {
    "siglip2-so400m-naflex": {
        "hf_id": "google/siglip2-so400m-patch16-naflex",
        "revision_prefix": "cc24074",
        "license": "Apache-2.0",
        "profile": "embeddings",
        "note": "semantic image/text joint space",
    },
    "dinov3-vitb16-lvd1689m": {
        "hf_id": "facebook/dinov3-vitb16-pretrain-lvd1689m",
        "revision_prefix": "5931719",
        "license": "DINOv3 License",
        "profile": "embeddings",
        "gated": True,
        "note": "visual clustering / junk and near-similarity representation",
    },
    "paddleocr-vl-1.6": {
        "hf_id": "PaddlePaddle/PaddleOCR-VL-1.6",
        "revision_prefix": "cdc88f5",
        "license": "Apache-2.0",
        "profile": "balanced",
        "note": "OCR escalation when native Vision OCR is weak",
    },
    "minicpm-v-4.6": {
        "hf_id": "openbmb/MiniCPM-V-4.6",
        "revision_prefix": "8169864",
        "license": "Apache-2.0",
        "profile": "balanced",
        "note": "first VLM fallback for ambiguous images",
    },
    "ling-3.0-tiny": {
        "hf_id": "inclusionAI/Ling-3.0-tiny",
        "revision_prefix": "b61f433",
        "license": "MIT",
        "profile": "quality",
        "note": "text/routing ambiguity fallback",
    },
    "lfm2.5-vl-3b": {
        "hf_id": "LiquidAI/LFM2.5-VL-3B",
        "revision_prefix": "5a414ea",
        "license": "LFM1.0",
        "profile": "quality",
        "note": "optional heavy VLM; non-Apache license, never bundled by default",
    },
    "internvl3.5-4b": {
        "hf_id": "OpenGVLab/InternVL3_5-4B",
        "revision_prefix": "481f6e3",
        "license": "Apache-2.0",
        "profile": "quality",
        "note": "optional heavy VLM",
    },
    "mimo-vl-7b-rl-2508": {
        "hf_id": "XiaomiMiMo/MiMo-VL-7B-RL-2508",
        "revision_prefix": "4bfb270",
        "license": "MIT",
        "profile": "quality",
        "note": "optional heaviest VLM; never resident by default",
    },
}

PROFILE_ORDER = {"embeddings": 0, "balanced": 1, "quality": 2}


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def regular_files(root: Path) -> Iterable[Path]:
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.name == "provenance.json" or ".cache" in path.parts:
            continue
        if path.is_symlink():
            raise RuntimeError(f"symlink is not allowed in a trusted model snapshot: {path}")
        yield path


def selected_for_profile(profile: str) -> list[str]:
    ceiling = PROFILE_ORDER[profile]
    return [name for name, spec in MODELS.items() if PROFILE_ORDER[spec["profile"]] <= ceiling]


def resolve_full_revision(hf, spec: dict) -> str:
    try:
        info = hf.HfApi().model_info(spec["hf_id"], revision=spec["revision_prefix"])
    except Exception as exc:
        extra = " This model is gated; accept its terms and authenticate with Hugging Face first." if spec.get("gated") else ""
        raise RuntimeError(f"cannot resolve {spec['hf_id']}@{spec['revision_prefix']}: {exc}.{extra}") from exc
    revision = str(getattr(info, "sha", "") or "")
    if len(revision) != 40 or not revision.startswith(spec["revision_prefix"]):
        raise RuntimeError(
            f"Hub resolved {spec['hf_id']} to unexpected revision {revision!r}; "
            f"expected prefix {spec['revision_prefix']}"
        )
    return revision


def build_manifest(name: str, spec: dict, dest: Path, revision: str) -> dict:
    files = {}
    root = dest.resolve()
    for path in regular_files(dest):
        resolved = path.resolve()
        try:
            relative = str(resolved.relative_to(root))
        except ValueError as exc:
            raise RuntimeError(f"model file escapes snapshot root: {path}") from exc
        files[relative] = sha256_file(path)
    if not files:
        raise RuntimeError(f"downloaded snapshot is empty: {dest}")
    return {
        "schema": 1,
        "model": name,
        "hf_id": spec["hf_id"],
        "revision": revision,
        "revision_prefix": spec["revision_prefix"],
        "license": spec["license"],
        "expected_files": files,
    }


def verify_one(name: str, require_revision: str | None = None) -> bool:
    spec = MODELS[name]
    dest = MODELS_ROOT / name
    try:
        record = json.loads((dest / "provenance.json").read_text())
    except Exception as exc:
        print(f"[{name}] missing/invalid provenance: {exc}", file=sys.stderr)
        return False
    revision = record.get("revision")
    if (
        record.get("schema") != 1
        or record.get("model") != name
        or record.get("hf_id") != spec["hf_id"]
        or record.get("license") != spec["license"]
        or record.get("revision_prefix") != spec["revision_prefix"]
        or not isinstance(revision, str)
        or len(revision) != 40
        or not revision.startswith(spec["revision_prefix"])
        or (require_revision is not None and revision != require_revision)
    ):
        print(f"[{name}] provenance identity mismatch", file=sys.stderr)
        return False
    expected = record.get("expected_files")
    if not isinstance(expected, dict) or not expected:
        print(f"[{name}] empty file manifest", file=sys.stderr)
        return False
    root = dest.resolve()
    for relative, expected_sha in expected.items():
        if not isinstance(relative, str) or not isinstance(expected_sha, str) or len(expected_sha) != 64:
            print(f"[{name}] malformed manifest entry {relative!r}", file=sys.stderr)
            return False
        path = dest / relative
        try:
            path.resolve().relative_to(root)
        except ValueError:
            print(f"[{name}] manifest path escapes root: {relative}", file=sys.stderr)
            return False
        if not path.is_file() or path.is_symlink():
            print(f"[{name}] missing/non-regular file: {relative}", file=sys.stderr)
            return False
        actual = sha256_file(path)
        if actual != expected_sha.lower():
            print(f"[{name}] SHA mismatch: {relative}", file=sys.stderr)
            return False
    actual_paths = {str(path.resolve().relative_to(root)) for path in regular_files(dest)}
    if actual_paths != set(expected):
        extras = sorted(actual_paths - set(expected))[:10]
        missing = sorted(set(expected) - actual_paths)[:10]
        print(f"[{name}] snapshot set changed; extra={extras} missing={missing}", file=sys.stderr)
        return False
    print(f"[{name}] verified {revision[:12]} · {len(expected)} files")
    return True


def provision_one(name: str) -> bool:
    spec = MODELS[name]
    try:
        import huggingface_hub as hf
    except ImportError:
        print("huggingface_hub is required for provisioning: pip install -U huggingface_hub", file=sys.stderr)
        return False
    try:
        revision = resolve_full_revision(hf, spec)
    except RuntimeError as exc:
        print(f"[{name}] {exc}", file=sys.stderr)
        return False
    dest = MODELS_ROOT / name
    dest.mkdir(parents=True, exist_ok=True)
    print(f"[{name}] {spec['hf_id']}@{revision[:12]} — {spec['note']}")
    print(f"  license: {spec['license']}")
    try:
        hf.snapshot_download(
            repo_id=spec["hf_id"],
            revision=revision,
            local_dir=str(dest),
            local_dir_use_symlinks=False,
        )
        manifest = build_manifest(name, spec, dest, revision)
        (dest / "provenance.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    except Exception as exc:
        extra = " Accept the gated model terms and authenticate first." if spec.get("gated") else ""
        print(f"[{name}] provisioning failed: {exc}.{extra}", file=sys.stderr)
        return False
    return verify_one(name, require_revision=revision)


def main() -> int:
    parser = argparse.ArgumentParser(description="Provision Private Librarian specialist models")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--profile", choices=sorted(PROFILE_ORDER, key=PROFILE_ORDER.get))
    parser.add_argument("--model", choices=sorted(MODELS))
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if args.list:
        for name, spec in MODELS.items():
            present = " [present]" if (MODELS_ROOT / name / "provenance.json").is_file() else ""
            gated = " gated" if spec.get("gated") else ""
            print(f"{name:28s} profile={spec['profile']:10s}{gated:7s} {spec['hf_id']} {spec['license']}{present}")
        return 0

    if bool(args.profile) == bool(args.model):
        parser.error("choose exactly one of --profile or --model")
    names = selected_for_profile(args.profile) if args.profile else [args.model]
    if args.profile == "quality" and not args.verify_only:
        print("WARNING: quality profile includes multiple multi-GB models; this is an explicit large download.", file=sys.stderr)
    MODELS_ROOT.mkdir(parents=True, exist_ok=True)
    ok = True
    for name in names:
        result = verify_one(name) if args.verify_only else provision_one(name)
        ok = result and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
