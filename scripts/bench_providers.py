#!/usr/bin/env python3
"""Offline provider decision benchmark for Issue #11 / #31.

This tool never downloads or mutates model directories. Missing artifacts or
packages produce executable unavailable records instead of native claims.
"""
from __future__ import annotations
import argparse, base64, importlib.util, json, os, statistics, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLIP_ID = "openai/clip-vit-base-patch32@3d74acf9"
CLIP_PREP = "resize224-centerCrop-normalize(mean=0.48145466,0.4578275,0.40821073;std=0.26862954,0.26130258,0.27577711)"
MCLIP_ID = "apple/coreml-mobileclip@3e0a7bfb"
MCLIP_PREP = "CoreML-256x256-ARGB-tokenBPE77"

def model_size_mb(path: Path) -> float:
    return round(sum(p.stat().st_size for p in path.rglob("*") if p.is_file()) / 1024**2, 1) if path.exists() else 0.0

def deps(names: list[str]) -> dict[str, bool]:
    return {name: importlib.util.find_spec(name) is not None for name in names}

def checkpoint(path: Path) -> bool:
    return (path / "config.json").is_file() and any((path / w).is_file() for w in ("pytorch_model.bin", "model.safetensors", "tf_model.h5", "flax_model.msgpack"))

def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    return round(ordered[min(len(ordered) - 1, max(0, int(len(ordered) * fraction) - 1))], 2)


def ppm_fixture() -> bytes:
    width = height = 64
    pixels = bytearray()
    for y in range(height):
        for x in range(width):
            pixels.extend((235, 20 if x < width // 2 else 235, 20 if y < height // 2 else 235))
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
    image = text = None
    fixture = base64.b64encode(ppm_fixture()).decode()
    try:
        for _ in range(max(1, samples)):
            image, image_ms = worker_request(proc, {"op": "image_b64", "data": fixture}, 512)
            text, text_ms = worker_request(proc, {"op": "clip_text", "data": "a red square"}, 512)
            image_latencies.append(image_ms)
            text_latencies.append(text_ms)
    finally:
        proc.terminate()
        try:
            proc.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.communicate(timeout=5)
    assert image is not None and text is not None
    a, b = image["vector"], text["vector"]
    dot = sum(x * y for x, y in zip(a, b))
    norm_a = sum(x * x for x in a) ** 0.5
    norm_b = sum(y * y for y in b) ** 0.5
    return {
        "status": "measured",
        "fixture": "deterministic-red-square-v1",
        "text_to_image": {"status": "measured", "cosine": round(dot / max(norm_a * norm_b, 1e-12), 6)},
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
    clip_ready = checkpoint(clip) and all(runtime[name] for name in ("torch", "transformers", "PIL"))
    mini_ready = checkpoint(mini) and all(runtime[name] for name in ("torch", "sentence_transformers"))
    out = {
        "provider": "python-transformers",
        "model": {"clip": CLIP_ID, "text": "sentence-transformers/all-MiniLM-L6-v2@1110a243"},
        "preprocessing": {"clip": CLIP_PREP, "text": "truncate4000-normalize"},
        "dimensions": {"clip_image": 512, "clip_joint": 512, "minilm_text": 384},
        "artifacts": {"clip": checkpoint(clip), "minilm": checkpoint(mini)},
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
            except Exception as exc:
                out["text_to_image"] = {"status": "unavailable", "reason": f"CLIP worker failed: {exc}"}
        if mini_ready:
            try:
                out["text_measurement"] = run_worker(model_dir, max(1, samples))
            except Exception as exc:
                out["text_measurement"] = {"status": "unavailable", "reason": f"MiniLM worker failed: {exc}"}
        out["status"] = "measured" if clip_ready or mini_ready else "unavailable"
        if out["status"] == "unavailable":
            out["reason"] = "Checkpoint artifacts are present but the required offline Python dependencies are missing."
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


def record_mobileclip(model_dir: Path, samples: int, native_binary: Path | None) -> dict:
    base = model_dir / "mobileclip-s0-coreml"
    image = [base / n for n in ("mobileclip_s0_image.mlmodelc", "mobileclip_s0_image.mlpackage") if (base / n).exists()]
    text = [base / n for n in ("mobileclip_s0_text.mlmodelc", "mobileclip_s0_text.mlpackage") if (base / n).exists()]
    tokenizer = [(base / n) for n in ("vocab.json", "merges.txt") if (base / n).is_file()]
    compiled = any(p.suffix == ".mlmodelc" for p in image) and any(p.suffix == ".mlmodelc" for p in text)
    available = compiled and len(tokenizer) == 2
    out = {
        "provider": "apple-coreml-mobileclip",
        "model": "apple/coreml-mobileclip@3e0a7bfb",
        "preprocessing": "CoreML-256x256-ARGB-tokenBPE77",
        "dimensions": {"image": 512, "joint": 512},
        "artifacts": {"image": [str(p) for p in image], "text": [str(p) for p in text], "tokenizer": [str(p) for p in tokenizer]},
        "dependencies": {"CoreML": True, "image_encoder": bool(image), "text_encoder": bool(text), "tokenizer": len(tokenizer) == 2},
        "status": "available-preflight" if available else "unavailable",
        "reason": "Compiled model pair and tokenizer are present; provider-smoke is the artifact-backed integration measurement." if available else "Both compiled image/text .mlmodelc artifacts and vocab.json/merges.txt are required.",
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
    native_measured = [r for r in records if r.get("status") == "measured" and r.get("provider") != "python-transformers"]
    python_measured = next((r for r in records if r.get("provider") == "python-transformers" and r.get("status") == "measured"), None)
    if native_measured:
        decision = {"winner": native_measured[0]["provider"], "fallback": "python-transformers", "reason": "Artifact-backed native provider smoke test is measured; review the golden retrieval result before making it default."}
    elif python_measured:
        decision = {"winner": "python-transformers", "fallback": "Vision feature-print", "reason": "Only the Python baseline has a measured local runtime; native candidates remain unsupported or unmeasured."}
    else:
        decision = {"winner": None, "fallback": "Vision feature-print", "reason": "No provider has an artifact-backed executable runtime on this machine."}
    payload = {"schema": 3, "issue": 11, "issue_companion": 31, "offline": True, "models_dir": str(args.models_dir), "providers": records, "decision": decision}
    args.output.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload, indent=2))
    return 0

if __name__ == "__main__": raise SystemExit(main())
