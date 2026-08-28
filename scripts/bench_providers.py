#!/usr/bin/env python3
"""Offline provider decision benchmark for Issue #11 / #31.

This tool never downloads or mutates model directories. Missing artifacts or
packages produce executable unavailable records instead of native claims.
"""
from __future__ import annotations
import argparse, base64, hashlib, importlib.util, json, os, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIP_ID = "openai/clip-vit-base-patch32@3d74acf9"
CLIP_PREP = "resize224-centerCrop-normalize(mean=0.48145466,0.4578275,0.40821073;std=0.26862954,0.26130258,0.27577711)"
MCLIP_ID = "apple/coreml-mobileclip@3e0a7bfb"
MCLIP_PREP = "CoreML-256x256-ARGB-tokenBPE77"


def repository_revision() -> str:
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True
        ).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=ROOT, text=True,
        ).strip()
        return f"{commit}+dirty" if dirty else commit
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def model_size_mb(path: Path) -> float:
    return round(sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) / 1024**2, 1) if path.exists() else 0.0

def deps(names: list[str]) -> dict[str, bool]:
    return {name: importlib.util.find_spec(name) is not None for name in names}

def checkpoint(path: Path) -> bool:
    return (path / "config.json").is_file() and any((path / w).is_file() for w in ("pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack"))


PYTHON_MODEL_SPECS = {
    "clip-vit-base-patch32": ("openai/clip-vit-base-patch32", "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268"),
    "all-MiniLM-L6-v2": ("sentence-transformers/all-MiniLM-L6-v2", "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"),
}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verified_python_model(path: Path, name: str) -> bool:
    """Require the same pinned, byte-manifested model contract as the helper."""
    identity = PYTHON_MODEL_SPECS.get(name)
    if identity is None:
        return False
    try:
        record = json.loads((path / "provenance.json").read_text())
    except Exception:
        return False
    if record.get("model") != name or record.get("hf_id") != identity[0] or record.get("revision") != identity[1]:
        return False
    expected_files = record.get("expected_files")
    if not isinstance(expected_files, dict) or not expected_files:
        return False
    weights = ("pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack")
    if "config.json" not in expected_files or not any(name in expected_files for name in weights):
        return False
    root = path.resolve()
    for relative, expected in expected_files.items():
        if not isinstance(relative, str) or not isinstance(expected, str) or len(expected) != 64:
            return False
        if any(char not in "0123456789abcdef" for char in expected.lower()):
            return False
        file_path = path / relative
        try:
            file_path.resolve().relative_to(root)
        except ValueError:
            return False
        if not file_path.is_file() or sha256_file(file_path) != expected.lower():
            return False
    return True

def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return round(ordered[min(len(ordered) - 1, max(0, int(len(ordered) * fraction) - 1))], 2)


CLIP_FIXTURE_QUERIES = ("a red square", "a green circle", "a blue triangle")


def ppm_fixture(index: int = 0, variant: int = 0) -> bytes:
    width = height = 64
    pixels = bytearray()
    colors = ((235, 20, 20), (20, 185, 40), (35, 85, 225))
    primary = colors[index % len(colors)]
    for y in range(height):
        for x in range(width):
            accent = (x + y + variant * 7) % 17 == 0
            pixels.extend(primary if not accent else (245, 245, 245))
    return f"P6\n{width} {height}\n255\n".encode() + bytes(pixels)


def worker_request(proc: subprocess.Popen[str], payload: dict, expected_dim: int) -> tuple[dict, float]:
    start = time.perf_counter()
    proc.stdin.write(json.dumps(payload) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    elapsed = (time.perf_counter() - start) * 1000
    result = json.loads(line) if line else {}
    if result.get("dim") != expected_dim or not isinstance(result.get("vector"), list) or len(result["vector"]) != expected_dim:
        raise RuntimeError(result.get("error", f"worker returned invalid {expected_dim}-d result"))
    return result, elapsed


def run_clip_worker(model_dir: Path, samples: int) -> dict:
    env = dict(os.environ)
    env.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "DO_NOT_TRACK": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "LIBRARIAN_MODELS_DIR": str(model_dir)})
    proc = subprocess.Popen([sys.executable, str(ROOT / "scripts" / "embed.py"), "--worker"], cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    image_latencies: list[float] = []
    text_latencies: list[float] = []
    image_vectors: list[list[float]] = []
    text_vectors: list[list[float]] = []
    try:
        for _ in range(max(1, samples)):
            for index, query in enumerate(CLIP_FIXTURE_QUERIES):
                fixture = base64.b64encode(ppm_fixture(index)).decode()
                image, image_ms = worker_request(
                    proc, {"op": "image_b64", "data": fixture}, 512
                )
                text, text_ms = worker_request(
                    proc, {"op": "clip_text", "data": query}, 512
                )
                image_latencies.append(image_ms)
                text_latencies.append(text_ms)
                image_vectors.append(image["vector"])
                text_vectors.append(text["vector"])
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate(timeout=5)
    def cosine(a: list[float], b: list[float]) -> float:
        dot = sum(x * y for x, y in zip(a, b))
        norm_a = sum(x * x for x in a) ** 0.5
        norm_b = sum(y * y for y in b) ** 0.5
        return dot / max(norm_a * norm_b, 1e-12)

    matrix = [
        [cosine(text_vector, image_vector) for image_vector in image_vectors]
        for text_vector in text_vectors
    ]
    correct = sum(
        max(range(len(row)), key=row.__getitem__) % len(CLIP_FIXTURE_QUERIES)
        == index % len(CLIP_FIXTURE_QUERIES)
        for index, row in enumerate(matrix)
    )
    diagonal = [
        row[index % len(CLIP_FIXTURE_QUERIES)]
        for index, row in enumerate(matrix)
    ]
    return {
        "status": "measured",
        "fixture": "golden-clip-colors-v1",
        "text_to_image": {
            "status": "measured",
            "cosine": round(sum(diagonal) / len(diagonal), 6),
            "recall_at_1": round(correct / len(matrix), 6),
            "queries": list(CLIP_FIXTURE_QUERIES),
        },
        "retrieval_quality": {
            "status": "measured",
            "text_to_image_recall_at_1": round(correct / len(matrix), 6),
            "fixture": "golden-clip-colors-v1",
        },
        "warm_calls": len(image_latencies),
        "image_latency_ms": {"p50": percentile(image_latencies, 0.50), "p95": percentile(image_latencies, 0.95)},
        "text_latency_ms": {"p50": percentile(text_latencies, 0.50), "p95": percentile(text_latencies, 0.95)},
    }


def run_worker(model_dir: Path, samples: int) -> dict:
    env = dict(os.environ)
    env.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "DO_NOT_TRACK": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "LIBRARIAN_MODELS_DIR": str(model_dir)})
    proc = subprocess.Popen([sys.executable, str(ROOT / "scripts" / "embed.py"), "--worker"], cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    latencies = []
    try:
        for _ in range(samples):
            start = time.perf_counter()
            proc.stdin.write(json.dumps({"op": "text", "data": "benchmark synthetic document"}) + "\n")
            proc.stdin.flush()
            line = proc.stdout.readline()
            latencies.append((time.perf_counter() - start) * 1000)
            result = json.loads(line) if line else {}
            if "vector" not in result or result.get("dim") != 384:
                return {"status": "unavailable", "reason": result.get("error", "worker returned invalid 384-d result"), "warm_calls": 0}
    finally:
        proc.terminate()
        proc.communicate(timeout=5)
    median = statistics.median(latencies)
    return {"status": "measured", "warm_calls": len(latencies), "latency_ms": {"p50": round(median, 2), "p95": percentile(latencies, .95)}, "throughput_per_s": round(1000 / median, 2)}

def record_local(model_dir: Path, samples: int) -> dict:
    clip, mini = model_dir / "clip-vit-base-patch32", model_dir / "all-MiniLM-L6-v2"
    runtime = deps(["torch", "transformers", "PIL", "sentence_transformers"])
    clip_verified = verified_python_model(clip, "clip-vit-base-patch32")
    mini_verified = verified_python_model(mini, "all-MiniLM-L6-v2")
    clip_ready = clip_verified and all(runtime[name] for name in ("torch", "transformers", "PIL"))
    mini_ready = mini_verified and all(runtime[name] for name in ("torch", "sentence_transformers"))
    out = {
        "provider": "python-transformers",
        "model": {"clip": CLIP_ID, "text": "sentence-transformers/all-MiniLM-L6-v2@1110a243"},
        "preprocessing": {"clip": CLIP_PREP, "text": "truncate4000-normalize"},
        "dimensions": {"clip_image": 512, "clip_joint": 512, "minilm_text": 384},
        "artifacts": {
            "clip": checkpoint(clip),
            "minilm": checkpoint(mini),
            "clip_provenance_verified": clip_verified,
            "minilm_provenance_verified": mini_verified,
        },
        "dependencies": runtime,
        "model_mb": round(model_size_mb(clip) + model_size_mb(mini), 1),
        "text_to_image": {"status": "not_measured", "reason": "CLIP checkpoint/runtime is not ready."},
        "retrieval_quality": {"status": "not_measured", "reason": "No labeled retrieval fixture supplied."},
        "fallback": {"status": "baseline"},
    }
    if not (checkpoint(clip) or checkpoint(mini)):
        out.update(status="unavailable", reason="No local checkpoint with config.json and weights was found.")
    else:
        if clip_ready:
            try:
                out["clip_measurement"] = run_clip_worker(model_dir, max(1, samples))
                out["text_to_image"] = out["clip_measurement"]["text_to_image"]
                out["retrieval_quality"] = out["clip_measurement"]["retrieval_quality"]
            except Exception as exc:
                out["text_to_image"] = {"status": "unavailable", "reason": f"CLIP worker failed: {exc}"}
        if mini_ready:
            try:
                out["text_measurement"] = run_worker(model_dir, max(1, samples))
            except Exception as exc:
                out["text_measurement"] = {"status": "unavailable", "reason": f"MiniLM worker failed: {exc}"}
        measured_clip = out.get("clip_measurement", {}).get("status") == "measured"
        measured_text = out.get("text_measurement", {}).get("status") == "measured"
        out["status"] = "measured" if measured_clip or measured_text else "unavailable"
        if out["status"] == "unavailable":
            out["reason"] = (
                "Checkpoint artifacts are present but provenance, pinned bytes, "
                "or the required offline Python dependencies are unavailable."
            )
    return out

def record_fileid(model_dir: Path) -> dict:
    onnx = list(model_dir.glob("**/*vit*32*.onnx"))
    text_onnx = list(model_dir.glob("**/*clip*text*.onnx"))
    coreml = list(model_dir.glob("**/*vit*32*.mlpackage")) + list(model_dir.glob("**/*vit*32*.mlmodelc"))
    runtime = deps(["onnxruntime"])
    available = bool(onnx and text_onnx and runtime["onnxruntime"])
    return {
        "provider": "fileid-openclip-compat",
        "model": CLIP_ID,
        "preprocessing": CLIP_PREP,
        "dimensions": {"image": 512, "joint": 512},
        "artifacts": {"image_onnx": [str(p) for p in onnx], "text_onnx": [str(p) for p in text_onnx], "coreml": [str(p) for p in coreml]},
        "dependencies": runtime,
        "status": "available-preflight" if available else "unavailable",
        "reason": "Matching image/text ONNX artifacts and onnxruntime are present; run provider-smoke for inference." if available else "Matching FileID-style image/text ONNX artifacts plus onnxruntime are required; preflight cannot claim a partial export.",
        "text_to_image": {"status": "not_measured", "reason": "Private Librarian does not yet ship an ONNX Runtime bridge."},
        "retrieval_quality": {"status": "not_measured", "reason": "No native FileID-compatible runtime integration exists in this checkout."},
        "fallback": {"status": "python-transformers"},
    }

def run_native_smoke(binary: Path, models_dir: Path, samples: int) -> dict | None:
    if not binary.is_file():
        return None
    env = dict(os.environ)
    env["LIBRARIAN_MODELS_DIR"] = str(models_dir)
    try:
        result = subprocess.run([str(binary), "provider-smoke", "--samples", str(max(1, samples))],
                                cwd=ROOT, env=env, text=True, capture_output=True, timeout=180, check=False)
        if result.returncode != 0:
            return {"status": "unavailable", "reason": result.stderr.strip() or "provider-smoke failed"}
        return json.loads(result.stdout)
    except (OSError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        return {"status": "unavailable", "reason": f"provider-smoke unavailable: {exc}"}


def verified_mobileclip(base: Path) -> bool:
    try:
        record = json.loads((base / "provenance.json").read_text())
    except Exception:
        return False
    if any(record.get(key) != value for key, value in {
        "coreml_repo": "apple/coreml-mobileclip",
        "coreml_revision": "3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947",
        "tokenizer_repo": "openai/clip-vit-base-patch32",
        "tokenizer_revision": "3d74acf9a28c67741b2f4f2ea7635f0aaf6f0268",
    }.items()):
        return False
    manifest = record.get("files_sha256")
    if not isinstance(manifest, dict) or not manifest:
        return False
    required = (
        "mobileclip_s0_image.mlpackage/",
        "mobileclip_s0_text.mlpackage/",
        "mobileclip_s0_image.mlmodelc/",
        "mobileclip_s0_text.mlmodelc/",
        "vocab.json",
        "merges.txt",
    )
    if not all(any(name == prefix or name.startswith(prefix) for name in manifest) for prefix in required):
        return False
    root = base.resolve()
    for relative, expected in manifest.items():
        if not isinstance(relative, str) or not isinstance(expected, str) or len(expected) != 64:
            return False
        if any(char not in "0123456789abcdef" for char in expected.lower()):
            return False
        path = base / relative
        try:
            path.resolve().relative_to(root)
        except ValueError:
            return False
        if not path.is_file() or sha256_file(path) != expected.lower():
            return False
    return True


def record_mobileclip(model_dir: Path, samples: int, native_binary: Path | None) -> dict:
    base = model_dir / "mobileclip-s0-coreml"
    image = [base / n for n in ("mobileclip_s0_image.mlmodelc", "mobileclip_s0_image.mlpackage") if (base / n).exists()]
    text = [base / n for n in ("mobileclip_s0_text.mlmodelc", "mobileclip_s0_text.mlpackage") if (base / n).exists()]
    tokenizer = [(base / n) for n in ("vocab.json", "merges.txt") if (base / n).is_file()]
    compiled = any(p.suffix == ".mlmodelc" for p in image) and any(p.suffix == ".mlmodelc" for p in text)
    provenance = verified_mobileclip(base)
    available = compiled and len(tokenizer) == 2 and provenance
    out = {
        "provider": "apple-coreml-mobileclip",
        "model": "apple/coreml-mobileclip@3e0a7bfb",
        "preprocessing": "CoreML-256x256-ARGB-tokenBPE77",
        "dimensions": {"image": 512, "joint": 512},
        "artifacts": {
            "image": [str(p) for p in image],
            "text": [str(p) for p in text],
            "tokenizer": [str(p) for p in tokenizer],
            "provenance_verified": provenance,
        },
        "dependencies": {"CoreML": True, "image_encoder": bool(image), "text_encoder": bool(text), "tokenizer": len(tokenizer) == 2},
        "status": "available-preflight" if available else "unavailable",
        "reason": (
            "Compiled model pair, tokenizer, and pinned provenance are present; "
            "provider-smoke is the artifact-backed integration measurement."
            if available
            else (
                "Compiled image/text .mlmodelc artifacts, tokenizer, and a "
                "matching verified provenance manifest are required."
            )
        ),
        "text_to_image": {"status": "requires_provider_smoke" if available else "not_measured"},
        "retrieval_quality": {"status": "not_measured", "reason": "Golden retrieval labels are not supplied to this command."},
        "fallback": {"status": "python-transformers"},
    }
    if available and native_binary is not None:
        measurement = run_native_smoke(native_binary, model_dir, samples)
        if measurement and measurement.get("status") == "measured":
            out["status"] = "measured"
            out["measurement"] = measurement
            out["text_to_image"] = {
                "status": "measured",
                "cosine": measurement.get("text_to_image_cosine"),
                "fixture": measurement.get("fixture"),
            }
        elif measurement:
            out["smoke"] = measurement
    return out

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=5)
    ap.add_argument("--output", type=Path, default=Path("bench-providers.json"))
    ap.add_argument("--models-dir", type=Path, default=Path(os.environ.get("LIBRARIAN_MODELS_DIR", ROOT / "Models")))
    ap.add_argument("--native-binary", type=Path, default=ROOT / ".build" / "release" / "librarian-cli")
    ap.add_argument("--providers", nargs="*", default=["local", "fileid", "coreml"])
    args = ap.parse_args()
    records = []
    for provider in args.providers:
        if provider in ("local", "python"): records.append(record_local(args.models_dir, args.samples))
        elif provider in ("fileid", "openclip"): records.append(record_fileid(args.models_dir))
        elif provider in ("coreml", "mobileclip"): records.append(record_mobileclip(args.models_dir, args.samples, args.native_binary))
        else: records.append({"provider": provider, "status": "unavailable", "reason": "Unknown provider"})
    comparable = [
        r for r in records
        if r.get("status") == "measured"
        and r.get("retrieval_quality", {}).get("status") == "measured"
    ]
    python_measured = next(
        (r for r in records
         if r.get("provider") == "python-transformers"
         and r.get("status") == "measured"
         and r.get("retrieval_quality", {}).get("status") == "measured"),
        None,
    )
    if len(comparable) >= 2:
        winner_record = max(
            comparable,
            key=lambda r: (
                r["retrieval_quality"].get("text_to_image_recall_at_1", 0),
                -r.get("clip_measurement", {}).get("image_latency_ms", {}).get("p95", float("inf")),
            ),
        )
        decision = {
            "winner": winner_record["provider"],
            "recommendation": "WINNER",
            "fallback": "python-transformers",
            "reason": "At least two providers have comparable labeled retrieval and runtime measurements; quality is ranked before latency.",
        }
    elif python_measured:
        decision = {
            "winner": None,
            "recommendation": "FALLBACK",
            "fallback": "python-transformers",
            "reason": "The Python baseline is measured, but no competing provider has a comparable labeled Golden retrieval result; no default promotion is justified.",
        }
    else:
        decision = {
            "winner": None,
            "recommendation": "FALLBACK",
            "fallback": "Vision feature-print",
            "reason": "No provider has an artifact-backed executable runtime with a comparable labeled retrieval result.",
        }
    payload = {
        "schema": 3,
        "issue": 11,
        "issue_companion": 31,
        "commit": repository_revision(),
        "offline": True,
        "models_dir": str(args.models_dir),
        "providers": records,
        "decision": decision,
    }
    args.output.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0

if __name__ == "__main__": raise SystemExit(main())
