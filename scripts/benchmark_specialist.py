#!/usr/bin/env python3
"""Measure Private Librarian's real SigLIP2 worker on the current host.

This benchmark is intentionally local/offline and synthetic:
- it never downloads or mutates a checkpoint;
- it talks to the production ``specialist.py --worker`` JSONL protocol;
- it uses a deterministic screenshot-shaped PNG, not files from the user's library;
- it reports measured sequential and bounded-batch throughput instead of an
  extrapolated "screenshots/sec" claim.

Run with the same isolated Python runtime that model setup installed, for example:

  "$LIBRARIAN_MODEL_RUNTIME_DIR/bin/python3" scripts/benchmark_specialist.py \
      --profile balanced --models-dir "$LIBRARIAN_SPECIALIST_MODELS_DIR"

Quality defaults to batches 1,2,4 on the 16-GB target class. Balanced also
tries batch 8. Pass ``--batch-sizes`` explicitly to override those defaults.
"""
from __future__ import annotations

import argparse
import base64
import io
import json
import math
import os
import platform
import select
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKER = ROOT / "scripts" / "specialist.py"
PROFILE_MODELS = {
    "balanced": ("siglip2-base-naflex", 768),
    "quality": ("siglip2-so400m-naflex", 1152),
}
MAX_BATCH = 8


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


def percentile(values: list[float], fraction: float) -> float | None:
    """Nearest-rank percentile so small samples never hide the slowest call."""
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * fraction) - 1))
    return round(ordered[index], 3)


def latency_summary(values: list[float]) -> dict[str, float | None]:
    if not values:
        return {"mean": None, "p50": None, "p95": None, "min": None, "max": None}
    return {
        "mean": round(statistics.fmean(values), 3),
        "p50": percentile(values, 0.50),
        "p95": percentile(values, 0.95),
        "min": round(min(values), 3),
        "max": round(max(values), 3),
    }


def process_rss_mb(pid: int) -> float | None:
    """Best-effort resident-set snapshot; not a promise of total MPS footprint."""
    try:
        output = subprocess.check_output(
            ["ps", "-o", "rss=", "-p", str(pid)], text=True, stderr=subprocess.DEVNULL
        ).strip()
        return round(int(output) / 1024, 1) if output else None
    except (OSError, ValueError, subprocess.CalledProcessError):
        return None


def screenshot_png(variant: int = 0) -> bytes:
    """Create a deterministic wide UI-like image without using user data."""
    try:
        from PIL import Image, ImageDraw
    except ImportError as exc:
        raise RuntimeError("Pillow is required by the specialist runtime") from exc

    width, height = 1440, 900
    image = Image.new("RGB", (width, height), (246, 246, 244))
    draw = ImageDraw.Draw(image)
    # Title/sidebar/chrome blocks approximate a desktop screenshot's geometry.
    draw.rectangle((0, 0, width, 66), fill=(38 + variant % 7, 40, 44))
    draw.rectangle((0, 66, 250, height), fill=(228, 229, 226))
    draw.rectangle((282, 105, width - 48, 172), fill=(220, 226, 235))
    for row in range(7):
        y = 215 + row * 78
        length = 730 + ((row * 97 + variant * 31) % 330)
        draw.rectangle((300, y, min(width - 65, 300 + length), y + 20), fill=(91, 96, 104))
        draw.rectangle((300, y + 31, min(width - 120, 690 + length // 2), y + 43), fill=(171, 175, 181))
    # Add a few variant-specific blocks so every batch entry has distinct bytes.
    x = 1040 + (variant * 17) % 120
    draw.rectangle((x, 730, min(width - 30, x + 170), 825), fill=(70, 119, 173))
    output = io.BytesIO()
    image.save(output, format="PNG", optimize=False)
    return output.getvalue()


def request(proc: subprocess.Popen[str], payload: dict, timeout: float = 180.0) -> tuple[dict, float]:
    if proc.stdin is None or proc.stdout is None:
        raise RuntimeError("worker pipes are unavailable")
    if proc.poll() is not None:
        stderr = proc.stderr.read() if proc.stderr is not None else ""
        raise RuntimeError(f"specialist worker already exited: {stderr[-1000:]}")

    started = time.perf_counter()
    proc.stdin.write(json.dumps(payload, separators=(",", ":")) + "\n")
    proc.stdin.flush()

    # The worker is request/response serial. Use select on POSIX so a bad MPS
    # shape/OOM cannot leave the benchmark blocked forever on readline().
    ready, _, _ = select.select([proc.stdout], [], [], max(0.001, timeout))
    if not ready:
        raise TimeoutError(f"specialist worker did not respond within {timeout:.1f}s")

    line = proc.stdout.readline()
    elapsed_ms = (time.perf_counter() - started) * 1000
    if not line:
        stderr = proc.stderr.read() if proc.stderr is not None else ""
        raise RuntimeError(f"specialist worker exited without a response: {stderr[-1000:]}")
    result = json.loads(line)
    if result.get("error"):
        raise RuntimeError(str(result["error"]))
    return result, elapsed_ms


def validate_single(result: dict, model_id: str, expected_dim: int) -> None:
    if result.get("model") != model_id:
        raise RuntimeError(f"worker returned unexpected model: {result.get('model')!r}")
    vector = result.get("vector")
    if result.get("dim") != expected_dim or not isinstance(vector, list) or len(vector) != expected_dim:
        raise RuntimeError(f"worker returned invalid {expected_dim}-D single embedding")


def validate_batch(result: dict, model_id: str, expected_dim: int, ids: list[str]) -> None:
    if result.get("model") != model_id or result.get("count") != len(ids):
        raise RuntimeError("worker returned a mismatched batch header")
    rows = result.get("items")
    if not isinstance(rows, list) or len(rows) != len(ids):
        raise RuntimeError("worker returned a mismatched batch row count")
    returned_ids = []
    for row in rows:
        if not isinstance(row, dict):
            raise RuntimeError("worker returned a malformed batch row")
        returned_ids.append(row.get("id"))
        vector = row.get("vector")
        if row.get("dim") != expected_dim or not isinstance(vector, list) or len(vector) != expected_dim:
            raise RuntimeError(f"worker returned an invalid {expected_dim}-D batch vector")
    if returned_ids != ids:
        raise RuntimeError("worker changed batch order or opaque ids")


def parse_batch_sizes(value: str | None, profile: str) -> list[int]:
    if value is None:
        return [1, 2, 4, 8] if profile == "balanced" else [1, 2, 4]
    sizes: list[int] = []
    for piece in value.split(","):
        try:
            size = int(piece.strip())
        except ValueError as exc:
            raise ValueError(f"invalid batch size {piece!r}") from exc
        if not 1 <= size <= MAX_BATCH:
            raise ValueError(f"batch sizes must be between 1 and {MAX_BATCH}")
        if size not in sizes:
            sizes.append(size)
    if not sizes:
        raise ValueError("at least one batch size is required")
    return sizes


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure the production SigLIP2 specialist worker")
    parser.add_argument("--profile", choices=sorted(PROFILE_MODELS), default="balanced")
    parser.add_argument("--models-dir", type=Path,
                        help="specialist model root; defaults to LIBRARIAN_SPECIALIST_MODELS_DIR or repo Models/specialists")
    parser.add_argument("--samples", type=int, default=5,
                        help="measured warm repetitions per sequential/batch shape")
    parser.add_argument("--batch-sizes",
                        help="comma-separated bounded batch sizes; defaults are profile-specific")
    parser.add_argument("--timeout", type=float, default=180.0,
                        help="maximum seconds for any one worker request")
    parser.add_argument("--output", type=Path, help="optional JSON output path")
    args = parser.parse_args()

    samples = max(1, min(50, args.samples))
    timeout = max(1.0, min(600.0, args.timeout))
    model_id, expected_dim = PROFILE_MODELS[args.profile]
    batch_sizes = parse_batch_sizes(args.batch_sizes, args.profile)
    models_dir = (
        args.models_dir
        or (Path(os.environ["LIBRARIAN_SPECIALIST_MODELS_DIR"])
            if os.environ.get("LIBRARIAN_SPECIALIST_MODELS_DIR") else None)
        or ROOT / "Models" / "specialists"
    ).expanduser().resolve()

    model_root = models_dir / model_id
    provenance = model_root / "provenance.json"
    if not provenance.is_file():
        payload = {
            "schema": 2,
            "status": "unavailable",
            "profile": args.profile,
            "model": model_id,
            "reason": f"provisioned model manifest not found at {provenance}",
        }
        encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(encoded)
        print(encoded, end="")
        return 2

    env = dict(os.environ)
    env.update({
        "HF_HUB_OFFLINE": "1",
        "TRANSFORMERS_OFFLINE": "1",
        "HF_DATASETS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1",
        "DO_NOT_TRACK": "1",
        "LIBRARIAN_SPECIALIST_MODELS_DIR": str(models_dir),
        "LIBRARIAN_SPECIALIST_MODELS_DIRS": str(models_dir),
    })
    proc = subprocess.Popen(
        [sys.executable, str(WORKER), "--worker"], cwd=ROOT, env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, bufsize=1,
    )

    fixtures = [screenshot_png(index) for index in range(MAX_BATCH)]
    encoded_fixtures = [base64.b64encode(value).decode("ascii") for value in fixtures]
    sequential_latencies: list[float] = []
    batch_results: list[dict] = []
    cold_ms: float | None = None
    try:
        single_payload = {
            "op": "siglip_image",
            "model": model_id,
            "data_b64": encoded_fixtures[0],
        }
        cold, cold_ms = request(proc, single_payload, timeout=timeout)
        validate_single(cold, model_id, expected_dim)
        rss_after_load = process_rss_mb(proc.pid)
        accelerator_memory_after_load, _ = request(proc, {"op": "memory"}, timeout=timeout)

        # The cold call above loads the model and warms the batch-1 graph. These
        # sequential calls therefore represent steady-state single-image work.
        for _ in range(samples):
            result, elapsed = request(proc, single_payload, timeout=timeout)
            validate_single(result, model_id, expected_dim)
            sequential_latencies.append(elapsed)
        sequential_total_s = sum(sequential_latencies) / 1000
        sequential_throughput = samples / sequential_total_s if sequential_total_s > 0 else 0.0
        accelerator_memory_after_sequential, _ = request(proc, {"op": "memory"}, timeout=timeout)

        for size in batch_sizes:
            ids = [f"fixture-{index}" for index in range(size)]
            payload = {
                "op": "siglip_image_batch",
                "model": model_id,
                "items": [
                    {"id": item_id, "data_b64": encoded_fixtures[index]}
                    for index, item_id in enumerate(ids)
                ],
            }

            # MPS/Transformers may compile/cache a new graph for each tensor
            # shape. Warm this exact batch shape once and exclude that cost from
            # steady-state throughput so the first call cannot poison the mean.
            warm_result, shape_warmup_ms = request(proc, payload, timeout=timeout)
            validate_batch(warm_result, model_id, expected_dim, ids)

            latencies: list[float] = []
            for _ in range(samples):
                result, elapsed = request(proc, payload, timeout=timeout)
                validate_batch(result, model_id, expected_dim, ids)
                latencies.append(elapsed)
            total_seconds = sum(latencies) / 1000
            throughput = (samples * size) / total_seconds if total_seconds > 0 else 0.0
            accelerator_memory, _ = request(proc, {"op": "memory"}, timeout=timeout)
            batch_results.append({
                "batch_size": size,
                "shape_warmup_latency_ms": round(shape_warmup_ms, 3),
                "calls": samples,
                "images": samples * size,
                "latency_ms": latency_summary(latencies),
                "images_per_second": round(throughput, 3),
                "throughput_vs_sequential": round(
                    throughput / sequential_throughput, 3
                ) if sequential_throughput > 0 else None,
                "process_rss_mb": process_rss_mb(proc.pid),
                "accelerator_memory": accelerator_memory,
            })

        payload = {
            "schema": 2,
            "status": "measured",
            "identity": {
                "commit": repository_revision(),
                "profile": args.profile,
                "model": model_id,
                "expected_dimension": expected_dim,
                "worker": "scripts/specialist.py",
                "python": sys.version.split()[0],
                "python_executable": sys.executable,
                "platform": platform.platform(),
                "machine": platform.machine(),
            },
            "fixture": {
                "name": "synthetic-desktop-screenshot-v1",
                "width": 1440,
                "height": 900,
                "source": "generated; no user files",
                "png_bytes": [len(value) for value in fixtures[:max(batch_sizes)]],
            },
            "cold_image_latency_ms": round(cold_ms or 0.0, 3),
            "rss_after_model_load_mb": rss_after_load,
            "accelerator_memory_after_model_load": accelerator_memory_after_load,
            "sequential": {
                "calls": samples,
                "latency_ms": latency_summary(sequential_latencies),
                "images_per_second": round(sequential_throughput, 3),
                "accelerator_memory": accelerator_memory_after_sequential,
            },
            "batches": batch_results,
            "notes": [
                "All measured timings include JSONL IPC, base64 decode, image preprocessing, model execution, copy-back, and JSON serialization.",
                "Each batch shape is warmed once before measured calls; shape_warmup_latency_ms is reported separately.",
                "p95 uses nearest-rank semantics so small sample sets do not hide the slowest observed request.",
                "process_rss_mb is a best-effort CPU/process RSS snapshot and excludes important MPS allocations.",
                "MPS current_allocated_bytes is tensor storage; driver_allocated_bytes includes allocator pools plus MPSGraph/Metal allocations. Neither is added to RSS as a fake total.",
                "recommended_max_bytes is Metal's recommended working-set ceiling, not installed physical RAM.",
                "Batch results are benchmark evidence only; production indexing remains sequential until target-Mac results justify a batch size.",
            ],
        }
    finally:
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate(timeout=5)

    encoded = json.dumps(payload, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded)
    print(encoded, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
