#!/usr/bin/env python3
"""Dependency-free tests for the specialist snapshot/protocol trust boundary."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("specialist.py")
PROVISIONER = Path(__file__).with_name("provision_specialist_models.py")
MODEL = "siglip2-so400m-naflex"


def load_module(path: Path, module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_worker(root: Path, roots: list[Path] | None = None):
    os.environ["LIBRARIAN_SPECIALIST_MODELS_DIR"] = str(root)
    if roots is None:
        os.environ.pop("LIBRARIAN_SPECIALIST_MODELS_DIRS", None)
    else:
        os.environ["LIBRARIAN_SPECIALIST_MODELS_DIRS"] = os.pathsep.join(map(str, roots))
    return load_module(SCRIPT, "private_librarian_specialist_test")


def write_snapshot(root: Path, extra: str | None = None) -> Path:
    model_root = root / MODEL
    model_root.mkdir(parents=True)
    payload = model_root / "weights.bin"
    payload.write_bytes(b"trusted test checkpoint")
    expected = {"weights.bin": hashlib.sha256(payload.read_bytes()).hexdigest()}
    if extra:
        expected[extra] = "0" * 64
    (model_root / "provenance.json").write_text(json.dumps({
        "schema": 1,
        "model": MODEL,
        "hf_id": "google/siglip2-so400m-patch16-naflex",
        "revision": "cc24074" + "0" * 33,
        "expected_files": expected,
    }))
    return model_root


class SpecialistContractTests(unittest.TestCase):
    def test_consumer_profiles_never_require_gated_models(self) -> None:
        provisioner = load_module(
            PROVISIONER, "private_librarian_provision_profile_test")
        for profile in ("embeddings", "balanced", "quality"):
            names = provisioner.selected_for_profile(profile)
            self.assertTrue(names, profile)
            gated = [name for name in names if provisioner.MODELS[name].get("gated", False)]
            self.assertEqual(gated, [], f"{profile} unexpectedly requires gated models")
        self.assertNotIn(
            "dinov3-vitb16-lvd1689m",
            provisioner.selected_for_profile("quality"),
        )
        self.assertTrue(provisioner.MODELS["dinov3-vitb16-lvd1689m"].get("gated"))

    def test_transformers_pooling_output_is_unwrapped_before_normalization(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module = load_worker(Path(directory))
            marker = object()

            class PoolingOutput:
                pooler_output = marker

            self.assertIs(module._embedding_tensor(PoolingOutput()), marker)

            class FullSiglipOutput:
                image_embeds = marker
                pooler_output = object()

            self.assertIs(module._embedding_tensor(FullSiglipOutput()), marker)

    def test_full_verification_detects_mutation_after_status_probe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = load_worker(root)
            model_root = write_snapshot(root)
            self.assertTrue(module._verify_snapshot(MODEL, verify_hashes=False))
            self.assertNotIn(MODEL, module._TRUSTED)
            model_root.joinpath("weights.bin").write_bytes(b"changed")
            self.assertFalse(module._verify_snapshot(MODEL, verify_hashes=True))

    def test_extra_file_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = load_worker(root)
            model_root = write_snapshot(root)
            model_root.joinpath("unexpected.bin").write_bytes(b"not in manifest")
            self.assertFalse(module._verify_snapshot(MODEL))

    def test_unsafe_manifest_path_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module = load_worker(root)
            write_snapshot(root, "../outside.bin")
            self.assertFalse(module._verify_snapshot(MODEL))

    def test_later_model_root_is_used_when_first_snapshot_is_invalid(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            parent = Path(directory)
            first = parent / "first"
            second = parent / "second"
            bad = write_snapshot(first)
            bad.joinpath("unexpected.bin").write_bytes(b"not in manifest")
            good = write_snapshot(second)
            module = load_worker(first, [first, second])
            self.assertTrue(module._verify_snapshot(MODEL))
            self.assertEqual(Path(module._model_dir(MODEL)).resolve(), good.resolve())


if __name__ == "__main__":
    unittest.main()
