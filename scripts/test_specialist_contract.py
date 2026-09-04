#!/usr/bin/env python3
"""Dependency-free tests for the specialist snapshot/protocol trust boundary."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


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
        self.assertIn("siglip2-base-naflex", provisioner.selected_for_profile("balanced"))
        self.assertNotIn("siglip2-so400m-naflex", provisioner.selected_for_profile("balanced"))
        self.assertIn("siglip2-so400m-naflex", provisioner.selected_for_profile("quality"))
        self.assertNotIn("siglip2-base-naflex", provisioner.selected_for_profile("quality"))

    def test_warm_encoders_use_mps_fp16_on_apple_silicon_hosts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module = load_worker(Path(directory))
            fp16_marker = object()

            class FakeMPS:
                @staticmethod
                def is_available() -> bool:
                    return True

            class FakeBackends:
                mps = FakeMPS()

            class FakeTorch:
                backends = FakeBackends()
                float16 = fp16_marker

            target, dtype = module._warm_encoder_target(FakeTorch(), platform="darwin")
            self.assertEqual(target, "mps")
            self.assertIs(dtype, fp16_marker)

            target, dtype = module._warm_encoder_target(FakeTorch(), platform="linux")
            self.assertEqual(target, "cpu")
            self.assertIsNone(dtype)

    def test_mps_memory_protocol_reports_allocator_and_driver_separately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            module = load_worker(Path(directory))
            fake_torch = types.ModuleType("torch")

            class FakeBackendMPS:
                @staticmethod
                def is_available() -> bool:
                    return True

            class FakeMPS:
                @staticmethod
                def current_allocated_memory() -> int:
                    return 750_000_000

                @staticmethod
                def driver_allocated_memory() -> int:
                    return 1_100_000_000

                @staticmethod
                def recommended_max_memory() -> int:
                    return 5_000_000_000

            fake_torch.backends = types.SimpleNamespace(mps=FakeBackendMPS())
            fake_torch.mps = FakeMPS()

            module._CACHE["siglip2-base-naflex"] = object()
            with patch.dict(sys.modules, {"torch": fake_torch}):
                result = module._handle({"op": "memory"})

            self.assertEqual(result["backend"], "mps")
            self.assertTrue(result["mps_available"])
            self.assertEqual(result["current_allocated_bytes"], 750_000_000)
            self.assertEqual(result["driver_allocated_bytes"], 1_100_000_000)
            self.assertEqual(result["recommended_max_bytes"], 5_000_000_000)
            self.assertEqual(result["resident"], ["siglip2-base-naflex"])
            # The protocol exposes independent measurements and never invents a
            # summed "total" that would double-count unified-memory mappings.
            self.assertNotIn("total_bytes", result)
            self.assertNotIn("rss_plus_mps_bytes", result)
            module._CACHE.clear()

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
