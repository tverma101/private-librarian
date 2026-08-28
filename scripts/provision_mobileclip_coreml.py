#!/usr/bin/env python3
"""Provision the pinned genuine MobileCLIP S0 Core ML artifacts.

This command is opt-in and networked. The app itself never downloads models;
it only reads the resulting files offline. The Core ML checkpoint and the
matching OpenAI CLIP tokenizer are pinned independently and recorded in
provenance.json.

Usage:
  python3 scripts/provision_mobileclip_coreml.py --download
  python3 scripts/provision_mobileclip_coreml.py --verify-only
  scripts/compile_mobileclip_coreml.sh
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DEST = ROOT / "Models" / "mobileclip-s0-coreml"
COREML_REPO = "apple/coreml-mobileclip"
COREML_REVISION = "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
TOKENIZER_REPO = "openai/clip-vit-base-patch32"
TOKENIZER_REVISION = "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268"
REQUIRED_COREML = (
    "mobileclip_s0_image.mlpackage",
    "mobileclip_s0_text.mlpackage",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(destination: Path) -> bool:
    missing = [name for name in REQUIRED_COREML if not (destination / name).is_dir()]
    missing += [name for name in ("vocab.json", "merges.txt") if not (destination / name).is_file()]
    if missing:
        print("missing: " + ", ".join(missing))
        return False
    provenance = destination / "provenance.json"
    try:
        record = json.loads(provenance.read_text())
    except Exception as exc:
        print(f"invalid provenance: {exc}")
        return False
    expected_identity = {
        "coreml_repo": COREML_REPO,
        "coreml_revision": COREML_REVISION,
        "tokenizer_repo": TOKENIZER_REPO,
        "tokenizer_revision": TOKENIZER_REVISION,
    }
    if any(record.get(key) != value for key, value in expected_identity.items()):
        print("provenance identity does not match the pinned revisions")
        return False
    if record.get("compiled"):
        missing_compiled = [
            name.replace(".mlpackage", ".mlmodelc")
            for name in REQUIRED_COREML
            if not (destination / name.replace(".mlpackage", ".mlmodelc")).is_dir()
        ]
        if missing_compiled:
            print("missing compiled artifacts: " + ", ".join(missing_compiled))
            return False
    manifest = record.get("files_sha256", {})
    if not isinstance(manifest, dict) or not manifest:
        print("provenance has no file SHA-256 manifest")
        return False
    required_prefixes = [*(f"{name}/" for name in REQUIRED_COREML), "vocab.json", "merges.txt"]
    if record.get("compiled"):
        required_prefixes += [
            f"{name.replace('.mlpackage', '.mlmodelc')}/"
            for name in REQUIRED_COREML
        ]
    if not all(
        any(name == prefix or name.startswith(prefix) for name in manifest)
        for prefix in required_prefixes
    ):
        print("provenance does not cover every required runtime artifact")
        return False
    mismatches = []
    root = destination.resolve()
    for relative, expected in manifest.items():
        path = destination / relative
        if (
            not isinstance(relative, str)
            or not isinstance(expected, str)
            or len(expected) != 64
            or any(char not in "0123456789abcdef" for char in expected.lower())
        ):
            mismatches.append(relative)
            continue
        try:
            path.resolve().relative_to(root)
        except ValueError:
            mismatches.append(relative)
            continue
        if not path.is_file() or sha256(path) != expected.lower():
            mismatches.append(relative)
    if mismatches:
        print("SHA-256 mismatch: " + ", ".join(mismatches))
        return False
    print(f"present: {destination}")
    for name in REQUIRED_COREML + ("vocab.json", "merges.txt"):
        path = destination / name
        print(f"  {name}: {sha256(path) if path.is_file() else 'package-tree-recorded'}")
    return True


def download(destination: Path) -> bool:
    try:
        from huggingface_hub import hf_hub_download, snapshot_download
    except ImportError:
        print("huggingface_hub is required; install it in an isolated provisioning environment")
        return False

    destination.mkdir(parents=True, exist_ok=True)
    snapshot_download(
        repo_id=COREML_REPO,
        revision=COREML_REVISION,
        local_dir=str(destination),
        allow_patterns=[*(f"{name}/**" for name in REQUIRED_COREML), "README.md", ".gitattributes"],
    )
    # The Core ML repository intentionally contains models, not tokenizer
    # assets. Keep the tokenizer beside the pair so the app's bytes-only
    # runtime has one explicit, auditable model root.
    for remote, local in (("vocab.json", "vocab.json"), ("merges.txt", "merges.txt")):
        cached = hf_hub_download(
            repo_id=TOKENIZER_REPO,
            filename=remote,
            revision=TOKENIZER_REVISION,
            local_dir=str(destination),
        )
        source = Path(cached)
        target = destination / local
        if source != target:
            shutil.copyfile(source, target)

    files = {}
    for path in sorted(destination.rglob("*")):
        if path.is_file() and ".cache" not in path.parts:
            files[str(path.relative_to(destination))] = sha256(path)
    (destination / "provenance.json").write_text(json.dumps({
        "coreml_repo": COREML_REPO,
        "coreml_revision": COREML_REVISION,
        "tokenizer_repo": TOKENIZER_REPO,
        "tokenizer_revision": TOKENIZER_REVISION,
        "files_sha256": files,
        "compiled": False,
    }, indent=2) + "\n")
    return verify(destination)


def main() -> int:
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--download", action="store_true")
    mode.add_argument("--verify-only", action="store_true")
    parser.add_argument("--destination", type=Path, default=DEFAULT_DEST)
    args = parser.parse_args()
    return 0 if (download(args.destination) if args.download else verify(args.destination)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
