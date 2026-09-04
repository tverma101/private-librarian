#!/usr/bin/env python3
"""Provision the optional Python embedding checkpoints used by the app.

Apple Vision is the zero-download baseline. This command only manages the two
Python checkpoints wired into ``embed.py``:

* ``clip-vit-base-patch32`` for image and joint text embeddings;
* ``all-MiniLM-L6-v2`` for semantic text embeddings.

The native MobileCLIP/Core ML path has a separate provisioner. Keeping the
registries separate prevents ``--all`` from downloading models that the app
cannot use.

Downloads are made at immutable Hugging Face revisions, written into a
temporary sibling directory, verified, and then installed by rename. A
partial or legacy directory is never treated as a usable model. Existing
invalid directories are moved aside with a recoverable name instead of being
deleted.

Examples:

  python3 scripts/provision_image_models.py --list
  python3 scripts/provision_image_models.py --model clip-vit-base-patch32
  python3 scripts/provision_image_models.py --all
  python3 scripts/provision_image_models.py --all --verify-only
  python3 scripts/provision_image_models.py --all --models-dir /path/to/Models

The app downloads only after an explicit setup action. Use
``scripts/setup_models.sh`` to install the isolated local runtime and these
checkpoints together. Without ``--models-dir``
the provisioner uses the user's Application Support model root.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import sys
import time
import uuid
from contextlib import contextmanager
from pathlib import Path, PurePosixPath
from typing import Any, Iterator

PROVENANCE_SCHEMA = 2
WEIGHT_NAMES = ("pytorch_model.bin", "model.safetensors")


# Only models consumed by scripts/embed.py belong in this registry. The
# explicit allowlists avoid downloading duplicate TensorFlow/Flax/ONNX exports
# that were present in an older cache and inflated the local tree to gigabytes.
MODELS: dict[str, dict[str, Any]] = {
    "clip-vit-base-patch32": {
        "hf_id": "openai/clip-vit-base-patch32",
        "revision": "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268",
        "size": "~610 MB",
        "license": "MIT",
        "note": "OpenAI CLIP ViT-B/32 — image and joint text embeddings",
        "allow_patterns": [
            "config.json",
            "preprocessor_config.json",
            "pytorch_model.bin",
            "merges.txt",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json",
        ],
        "required_files": [
            "config.json",
            "preprocessor_config.json",
            "pytorch_model.bin",
            "merges.txt",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.json",
        ],
    },
    "all-MiniLM-L6-v2": {
        "hf_id": "sentence-transformers/all-MiniLM-L6-v2",
        "revision": "1110a243fdf4706b3f48f1d95db1a4f5529b4d41",
        "size": "~95 MB",
        "license": "Apache-2.0",
        "note": "MiniLM — 384-d semantic text embeddings",
        "allow_patterns": [
            "1_Pooling/config.json",
            "config.json",
            "config_sentence_transformers.json",
            "modules.json",
            "model.safetensors",
            "sentence_bert_config.json",
            "special_tokens_map.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.txt",
        ],
        "required_files": [
            "1_Pooling/config.json",
            "config.json",
            "modules.json",
            "model.safetensors",
            "sentence_bert_config.json",
            "tokenizer.json",
            "tokenizer_config.json",
            "vocab.txt",
        ],
    },
}


class ProvisioningError(RuntimeError):
    """An actionable provisioning or verification failure."""


def default_models_dir() -> Path:
    configured = os.environ.get("LIBRARIAN_MODELS_DIR")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / "Library/Containers/com.tejas.private-librarian/Data/Library/Application Support/PrivateLibrarian/Models"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_relative_path(relative: str) -> bool:
    """Return whether a manifest path is a plain, root-relative POSIX path."""
    if not isinstance(relative, str) or not relative or "\\" in relative:
        return False
    path = PurePosixPath(relative)
    return not path.is_absolute() and all(part not in ("", ".", "..") for part in path.parts)


def regular_files(root: Path) -> tuple[dict[str, Path], str | None]:
    """Collect regular, non-symlink files below root, excluding HF caches."""
    if not root.is_dir() or root.is_symlink():
        return {}, "model directory is missing or is a symlink"
    files: dict[str, Path] = {}
    try:
        paths = sorted(root.rglob("*"))
    except OSError as exc:
        return {}, f"cannot enumerate model directory: {exc}"
    for path in paths:
        relative_path = path.relative_to(root)
        if ".cache" in relative_path.parts:
            continue
        relative = relative_path.as_posix()
        if path.is_symlink():
            return {}, f"symlink is not allowed in model artifacts: {relative}"
        if path.is_file():
            if relative == "provenance.json":
                continue
            if not safe_relative_path(relative):
                return {}, f"unsafe model artifact path: {relative}"
            files[relative] = path
    return files, None


def identity_matches(record: dict[str, Any], name: str, spec: dict[str, Any]) -> bool:
    return (
        record.get("schema") == PROVENANCE_SCHEMA
        and record.get("model") == name
        and record.get("hf_id") == spec["hf_id"]
        and record.get("revision") == spec["revision"]
    )


def verify_directory(destination: Path, name: str, *, check_hashes: bool = True) -> tuple[bool, str]:
    """Verify one model directory without contacting the network."""
    spec = MODELS[name]
    if not destination.is_dir() or destination.is_symlink():
        return False, "model directory is missing"
    provenance = destination / "provenance.json"
    try:
        record = json.loads(provenance.read_text(encoding="utf-8"))
    except Exception as exc:
        return False, f"missing or invalid provenance.json: {exc}"
    if not isinstance(record, dict) or not identity_matches(record, name, spec):
        return False, "provenance identity or schema does not match the pinned checkpoint"

    expected_files = record.get("expected_files")
    if not isinstance(expected_files, dict) or not expected_files:
        return False, "provenance has no file SHA-256 manifest"
    if record.get("required_files") != spec["required_files"]:
        return False, "provenance required-file contract does not match this runtime"

    files, error = regular_files(destination)
    if error:
        return False, error
    actual_names = set(files)
    manifest_names = set(expected_files)
    if actual_names != manifest_names:
        missing = sorted(manifest_names - actual_names)
        extra = sorted(actual_names - manifest_names)
        detail = []
        if missing:
            detail.append("missing=" + ",".join(missing[:4]))
        if extra:
            detail.append("unrecorded=" + ",".join(extra[:4]))
        return False, "manifest does not describe installed files (" + "; ".join(detail) + ")"

    for relative in spec["required_files"]:
        if relative not in expected_files:
            return False, f"required file is absent from provenance: {relative}"
    if not any(relative in expected_files for relative in WEIGHT_NAMES):
        return False, "provenance does not cover a supported model weight"

    for relative, expected in expected_files.items():
        if not safe_relative_path(relative):
            return False, f"unsafe manifest path: {relative!r}"
        if not isinstance(expected, str) or len(expected) != 64 or any(
            char not in "0123456789abcdef" for char in expected.lower()
        ):
            return False, f"invalid SHA-256 for {relative}"
        path = files.get(relative)
        if path is None or not path.is_file() or path.is_symlink():
            return False, f"manifest file is not a regular file: {relative}"
        if check_hashes and sha256_file(path) != expected.lower():
            return False, f"SHA-256 mismatch for {relative}"
    return True, "ready"


def verify_model(models_dir: Path, name: str, *, check_hashes: bool = True) -> tuple[bool, str]:
    return verify_directory(models_dir / name, name, check_hashes=check_hashes)


def ensure_hf() -> Any:
    try:
        import huggingface_hub
    except ImportError as exc:
        raise ProvisioningError(
            "huggingface_hub is not installed. Run scripts/setup_models.sh "
            "or install the isolated provisioning runtime."
        ) from exc
    return huggingface_hub


def expected_lfs_files(hf: Any, spec: dict[str, Any]) -> dict[str, str]:
    """Return Git-LFS SHA-256 digests for allowed files at the pin."""
    try:
        info = hf.HfApi().model_info(spec["hf_id"], revision=spec["revision"])
    except Exception as exc:
        raise ProvisioningError(
            f"cannot resolve the pinned revision manifest for {spec['hf_id']}: {exc}"
        ) from exc
    expected: dict[str, str] = {}
    allow = set(spec["allow_patterns"])
    for sibling in getattr(info, "siblings", []) or []:
        name = getattr(sibling, "rfilename", None)
        if not isinstance(name, str) or not any(fnmatch.fnmatch(name, pattern) for pattern in allow):
            continue
        lfs = getattr(sibling, "lfs", None)
        oid = lfs.get("oid") if isinstance(lfs, dict) else getattr(lfs, "oid", None)
        if isinstance(oid, str) and len(oid) == 64:
            expected[name] = oid.lower()
    return expected


@contextmanager
def model_lock(root: Path) -> Iterator[None]:
    """Serialize installs sharing one model root when flock is available."""
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / ".provision.lock"
    with lock_path.open("a+") as handle:
        try:
            import fcntl

            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        except ImportError:
            pass
        try:
            yield
        finally:
            try:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            except ImportError:
                pass


def _move_path(source: Path, target: Path) -> None:
    source.rename(target)


def archive_existing(destination: Path, *, move=_move_path) -> Path:
    stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime())
    archive = destination.with_name(f".{destination.name}.previous-{stamp}-{os.getpid()}")
    while archive.exists():
        archive = destination.with_name(
            f".{destination.name}.previous-{stamp}-{os.getpid()}-{uuid.uuid4().hex[:6]}"
        )
    move(destination, archive)
    return archive


def activate_download(partial: Path, destination: Path, *, move=_move_path) -> Path | None:
    """Atomically activate a verified download with rollback on rename failure."""
    archived: Path | None = None
    if destination.exists() or destination.is_symlink():
        archived = archive_existing(destination, move=move)
    try:
        move(partial, destination)
    except Exception as activation_error:
        if (
            archived is not None
            and (archived.exists() or archived.is_symlink())
            and not (destination.exists() or destination.is_symlink())
        ):
            try:
                move(archived, destination)
            except Exception as restore_error:
                raise ProvisioningError(
                    "model activation failed and the previous checkpoint could not "
                    f"be restored automatically; recover {archived} to {destination}"
                ) from restore_error
        raise activation_error

    if archived is not None:
        for candidate in destination.parent.glob(f".{destination.name}.previous-*"):
            if candidate == archived:
                continue
            if candidate.is_dir() and not candidate.is_symlink():
                shutil.rmtree(candidate, ignore_errors=True)
    return archived


def download_one(name: str, models_dir: Path, *, force: bool = False) -> bool:
    spec = MODELS[name]
    destination = models_dir / name
    ready, reason = verify_model(models_dir, name, check_hashes=True)
    if ready and not force:
        print(f"[{name}] ready: {destination}")
        return True

    hf = ensure_hf()
    models_dir.mkdir(parents=True, exist_ok=True)
    print(f"[{name}] downloading {spec['hf_id']} @ {spec['revision'][:12]} ({spec['size']})")
    if destination.exists() or destination.is_symlink():
        print(f"  existing directory is not usable ({reason}); it will be preserved after verification")

    partial = models_dir / f".{name}.partial-{os.getpid()}-{uuid.uuid4().hex[:8]}"
    try:
        partial.mkdir(parents=True)
        remote_lfs = expected_lfs_files(hf, spec)
        try:
            hf.snapshot_download(
                repo_id=spec["hf_id"],
                revision=spec["revision"],
                local_dir=str(partial),
                allow_patterns=spec["allow_patterns"],
            )
        except TypeError as exc:
            raise ProvisioningError(
                "the installed huggingface_hub does not support pinned local downloads; "
                "rerun scripts/setup_models.sh"
            ) from exc

        files, error = regular_files(partial)
        if error:
            raise ProvisioningError(error)
        if not all(relative in files for relative in spec["required_files"]):
            missing = [relative for relative in spec["required_files"] if relative not in files]
            raise ProvisioningError("download is missing required files: " + ", ".join(missing))
        if not any(relative in files for relative in WEIGHT_NAMES):
            raise ProvisioningError("download has no supported model weight")

        expected_files: dict[str, str] = {}
        mismatches: list[str] = []
        for relative, path in files.items():
            digest = sha256_file(path)
            expected_files[relative] = digest
            remote_digest = remote_lfs.get(relative)
            if remote_digest is not None and remote_digest != digest:
                mismatches.append(relative)
        if mismatches:
            raise ProvisioningError("Git-LFS SHA-256 mismatch: " + ", ".join(sorted(mismatches)))

        record = {
            "schema": PROVENANCE_SCHEMA,
            "model": name,
            "hf_id": spec["hf_id"],
            "revision": spec["revision"],
            "license": spec["license"],
            "required_files": spec["required_files"],
            "expected_files": dict(sorted(expected_files.items())),
        }
        (partial / "provenance.json").write_text(
            json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        ready, reason = verify_directory(partial, name, check_hashes=True)
        if not ready:
            raise ProvisioningError("post-download verification failed: " + reason)
        archived = activate_download(partial, destination)
        if archived is not None:
            print(f"  preserved previous directory at {archived}")
        print(f"[{name}] installed: {destination}")
        return True
    except (OSError, ProvisioningError) as exc:
        print(f"[{name}] failed: {exc}", file=sys.stderr)
        if partial.exists():
            print(f"  partial download preserved for inspection: {partial}", file=sys.stderr)
        return False


def print_status(models_dir: Path) -> None:
    print(f"Models directory: {models_dir}")
    print("Only wired Python checkpoints are listed; MobileCLIP uses its separate Core ML provisioner.")
    for name, spec in MODELS.items():
        ready, reason = verify_model(models_dir, name, check_hashes=True)
        if ready:
            state = "ready"
        elif (models_dir / name).exists():
            state = "incomplete"
        else:
            state = "missing"
        print(f"  {name:28s} {state:10s} {spec['note']}")
        if state == "incomplete":
            print(f"    {reason}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Provision pinned local embedding checkpoints")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--list", action="store_true", help="Show model status without network access")
    mode.add_argument("--all", action="store_true", help="Download or verify both wired Python models")
    mode.add_argument("--model", choices=sorted(MODELS), help="Download or verify one wired model")
    parser.add_argument("--verify-only", action="store_true", help="Verify local bytes only; never contact Hugging Face")
    parser.add_argument("--force", action="store_true", help="Redownload a ready model and preserve the old directory")
    parser.add_argument("--models-dir", type=Path, default=default_models_dir(), help="Model root (default: repo Models/ or LIBRARIAN_MODELS_DIR)")
    args = parser.parse_args(argv)
    models_dir = args.models_dir.expanduser().resolve()

    if args.list:
        print_status(models_dir)
        return 0

    names = sorted(MODELS) if args.all else [args.model]
    assert all(name is not None for name in names)
    ok = True
    with model_lock(models_dir):
        for name in names:
            assert name is not None
            if args.verify_only:
                ready, reason = verify_model(models_dir, name, check_hashes=True)
                print(f"[{name}] {'ready' if ready else 'NOT READY'}: {reason}")
                ok = ok and ready
            else:
                ok = download_one(name, models_dir, force=args.force) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
