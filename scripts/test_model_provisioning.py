#!/usr/bin/env python3
"""Offline regression tests for the model manifest contract."""
from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import provision_image_models as provisioner


class ModelProvisioningTests(unittest.TestCase):
    def test_valid_manifest_and_hashes(self) -> None:
        name = "all-MiniLM-L6-v2"
        spec = provisioner.MODELS[name]
        with tempfile.TemporaryDirectory(prefix="private-librarian-model-test-") as raw_root:
            root = Path(raw_root)
            model_dir = root / name
            for relative in spec["required_files"]:
                path = model_dir / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(f"fixture:{relative}\n".encode())

            expected = {
                relative: provisioner.sha256_file(model_dir / relative)
                for relative in sorted(spec["required_files"])
            }
            (model_dir / "provenance.json").write_text(
                json.dumps({
                    "schema": provisioner.PROVENANCE_SCHEMA,
                    "model": name,
                    "hf_id": spec["hf_id"],
                    "revision": spec["revision"],
                    "license": spec["license"],
                    "required_files": spec["required_files"],
                    "expected_files": expected,
                }),
                encoding="utf-8",
            )

            self.assertEqual(provisioner.verify_model(root, name), (True, "ready"))

            (model_dir / "model.safetensors").write_bytes(b"tampered")
            ready, reason = provisioner.verify_model(root, name)
            self.assertFalse(ready)
            self.assertIn("SHA-256 mismatch", reason)

    def test_legacy_or_partial_directory_is_not_ready(self) -> None:
        name = "clip-vit-base-patch32"
        with tempfile.TemporaryDirectory(prefix="private-librarian-model-test-") as raw_root:
            root = Path(raw_root)
            model_dir = root / name
            model_dir.mkdir(parents=True)
            (model_dir / "config.json").write_text("{}", encoding="utf-8")
            (model_dir / "pytorch_model.bin").write_bytes(b"legacy")
            ready, reason = provisioner.verify_model(root, name)
            self.assertFalse(ready)
            self.assertIn("provenance.json", reason)


if __name__ == "__main__":
    unittest.main()
