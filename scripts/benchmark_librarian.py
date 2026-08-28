#!/usr/bin/env python3
"""Synthetic benchmark harness for Private Librarian — Issue #10.

Never points at real user folders. Generates an isolated temporary library
under a synthetic tempfile root, runs the existing CLI, and emits
machine-readable JSON + a short console table.

One-command 10k:
  python3 scripts/benchmark_librarian.py --files 10000
  python3 scripts/benchmark_librarian.py --files 10000 --tier2
  python3 scripts/benchmark_librarian.py --files 100000

Metrics (all synthetic + local):
  cold index throughput, unchanged warm re-scan cost, one-file incremental
  re-index, duplicate detection, FTS/semantic/CLIP latency loops,
  virtual-graph query latency, model-worker warmup, wall time, files/sec,
  peak RSS where available, DB/embedding size, and per-stage counts.
  Tier-1-only and Tier-2-enabled modes.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

try:
    import resource as _resource
except ImportError:
    _resource = None
try:
    import psutil as _psutil
except ImportError:
    _psutil = None

BENCHMARK_KEY_HEX = "11" * 32
SEARCH_ITERS = 20
_RSS_INTERVAL_S = 0.05


def repository_revision() -> str:
    root = Path(__file__).resolve().parent.parent
    try:
        commit = subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"], cwd=root, text=True
        ).strip()
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=normal"],
            cwd=root, text=True,
        ).strip()
        return f"{commit}+dirty" if dirty else commit
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def generate_library(root: Path, files: int) -> None:
    courses = ("CSC-151", "MAT-171", "ENG-112")
    for i in range(files):
        course = courses[i % len(courses)]
        bucket = root / course / f"unit-{i % 16:02d}"
        bucket.mkdir(parents=True, exist_ok=True)
        body = (
            f"{course} synthetic benchmark document {i}\n"
            f"assignment unit {i % 16}; deterministic fixture only\n"
            f"token-{hashlib.sha256(str(i).encode()).hexdigest()[:24]}\n"
        )
        (bucket / f"doc-{i:06d}.txt").write_text(body, encoding="utf-8")
    if files >= 20:
        payload = b"private-librarian-benchmark-duplicate\n" * 128
        dup = root / "duplicates"
        dup.mkdir(parents=True, exist_ok=True)
        (dup / "copy-a.bin").write_bytes(payload)
        (dup / "copy-b.bin").write_bytes(payload)
    if files >= 1:
        try:
            png = bytes.fromhex(
                "89504e470d0a1a0a0000000d49484452000000010000000108000000001a"
                "9a6cb40000000c4944415408d763f8cfc0000000030001"
                "7dd2dbef0000000049454e44ae426082"
            )
            img_dir = root / "Images"
            img_dir.mkdir(parents=True, exist_ok=True)
            for k in range(min(4, max(1, files // 2500))):
                (img_dir / f"bench-img-{k:02d}.png").write_bytes(png)
        except Exception:
            pass


def peak_rss_mb() -> float | None:
    if _psutil is not None:
        try:
            return _psutil.Process().memory_info().rss / (1024 * 1024)
        except Exception:
            pass
    if _resource is not None:
        try:
            rss = _resource.getrusage(_resource.RUSAGE_SELF).ru_maxrss
            if rss > 10 * 1024 * 1024:
                return rss / (1024 * 1024)
            return rss / 1024
        except Exception:
            pass
    return None


def catalog_stats(catalog: Path) -> dict:
    db_size = 0
    for p in [catalog, Path(str(catalog) + "-wal"), Path(str(catalog) + "-shm")]:
        try:
            db_size += p.stat().st_size
        except Exception:
            pass
    return {"db_size_bytes": db_size}


def per_stage_counts_via_status(binary: Path, catalog: Path) -> dict | None:
    env = dict(os.environ)
    env["LIBRARIAN_CATALOG_KEY"] = BENCHMARK_KEY_HEX
    try:
        proc = subprocess.run(
            [str(binary), "status", "--catalog", str(catalog)],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        if proc.returncode != 0:
            return None
        counts: dict[str, int] = {}
        for kv in re.findall(r"(\w+)=(\d+)", proc.stdout):
            counts[kv[0]] = int(kv[1])
        return counts if counts else None
    except Exception:
        return None


def run_cli(binary: Path, catalog: Path, command: list[str], tier2: bool = False) -> dict:
    env = dict(os.environ)
    env["LIBRARIAN_CATALOG_KEY"] = BENCHMARK_KEY_HEX
    full = [str(binary), *command, "--catalog", str(catalog)]
    if tier2:
        full.append("--tier2")
    rss_samples: list[float] = []
    started = time.perf_counter()
    proc = subprocess.Popen(full, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        child = _psutil.Process(proc.pid) if _psutil is not None else None
    except Exception:
        child = None
    rss_peak = None
    while proc.poll() is None:
        if child is not None:
            try:
                rss = child.memory_info().rss / (1024 * 1024)
                rss_samples.append(rss)
                for c in child.children(recursive=True):
                    try:
                        rss_samples.append(c.memory_info().rss / (1024 * 1024))
                    except Exception:
                        pass
            except Exception:
                pass
        time.sleep(_RSS_INTERVAL_S)
    try:
        out, err = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
    elapsed = time.perf_counter() - started
    if rss_samples:
        rss_peak = max(rss_samples)
    if rss_peak is None:
        rss_peak = peak_rss_mb()
    indexed = None
    dupes = None
    m = re.search(r"indexed\s+(\d+)\s+files", out)
    if m:
        indexed = int(m.group(1))
    m2 = re.search(r"duplicate groups:\s*(\d+)", out)
    if m2:
        dupes = int(m2.group(1))
    metrics = {}
    metric_line = re.search(r"work-metrics\s+([^\n]+)", out)
    if metric_line:
        metrics = {
            key: int(value)
            for key, value in re.findall(r"(\w+)=(\d+)", metric_line.group(1))
        }
    similarity = {}
    similarity_line = re.search(r"similarity-metrics\s+([^\n]+)", out)
    if similarity_line:
        for key, value in re.findall(r"(\w+)=([0-9.]+)", similarity_line.group(1)):
            similarity[key] = float(value) if "." in value else int(value)
    return {
        "command": full[1:],
        "seconds": elapsed,
        "returncode": proc.returncode,
        "indexed": indexed,
        "dupes_groups": dupes,
        "work_metrics": metrics,
        "similarity_metrics": similarity,
        "rss_peak_mb": round(rss_peak, 1) if rss_peak is not None else None,
        "stdout_tail": out[-2000:],
        "stderr_tail": err[-2000:],
    }


def time_search_loop(binary: Path, catalog: Path, query: str,
                     iters: int = SEARCH_ITERS, tier2: bool = False) -> dict:
    env = dict(os.environ)
    env["LIBRARIAN_CATALOG_KEY"] = BENCHMARK_KEY_HEX
    latencies: list[float] = []
    last_rc = 0
    last_out = ""
    for _ in range(iters):
        t0 = time.perf_counter()
        command = [str(binary), "search", query, "--catalog", str(catalog)]
        if tier2:
            command.append("--tier2")
        proc = subprocess.run(
            command,
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        latencies.append(time.perf_counter() - t0)
        last_rc = proc.returncode
        last_out = proc.stdout[-600:]
        if proc.returncode != 0:
            break
    latencies.sort()
    p50 = latencies[len(latencies)//2] if latencies else None
    p95 = latencies[int(len(latencies)*0.95)] if latencies else None
    if p95 is not None and p95 >= len(latencies):
        p95 = latencies[-1]
    return {
        "query": query,
        "iters": len(latencies),
        "p50_ms": round(p50*1000, 2) if p50 is not None else None,
        "p95_ms": round(p95*1000, 2) if p95 is not None else None,
        "mean_ms": round(sum(latencies)/len(latencies)*1000, 2) if latencies else None,
        "returncode": last_rc,
        "sample_tail": last_out,
    }


def time_graph_loop(binary: Path, catalog: Path, iters: int = 3) -> dict:
    env = dict(os.environ)
    env["LIBRARIAN_CATALOG_KEY"] = BENCHMARK_KEY_HEX
    latencies: list[float] = []
    last_rc = 0
    last_out = ""
    for _ in range(max(1, iters)):
        t0 = time.perf_counter()
        proc = subprocess.run(
            [str(binary), "graph-stats", "--catalog", str(catalog)],
            env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
        )
        latencies.append(time.perf_counter() - t0)
        last_rc = proc.returncode
        last_out = proc.stdout[-600:]
        if proc.returncode != 0:
            break
    latencies.sort()
    p50 = latencies[len(latencies) // 2] if latencies else None
    p95 = latencies[min(len(latencies) - 1, max(0, int(len(latencies) * 0.95)))] if latencies else None
    return {
        "query": "organization-graph",
        "iters": len(latencies),
        "p50_ms": round(p50 * 1000, 2) if p50 is not None else None,
        "p95_ms": round(p95 * 1000, 2) if p95 is not None else None,
        "mean_ms": round(sum(latencies) / len(latencies) * 1000, 2) if latencies else None,
        "returncode": last_rc,
        "sample_tail": last_out,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Private Librarian benchmark harness (Issue #10)")
    ap.add_argument("--binary", type=Path, default=Path(".build/release/librarian-cli"))
    ap.add_argument("--files", type=int, default=10_000, help="Synthetic file count (default 10000; 100000 opt-in)")
    ap.add_argument("--output", type=Path, default=Path("benchmark-result.json"))
    ap.add_argument("--keep-fixture", action="store_true")
    ap.add_argument("--tier2", action="store_true", help="Enable Tier-2 local embeddings when Models/ provisioned")
    ap.add_argument("--search-iters", type=int, default=SEARCH_ITERS)
    ap.add_argument("--relation-iters", type=int, default=3)
    args = ap.parse_args()
    binary = args.binary.resolve()
    if not binary.exists():
        alt = Path(".build/debug/librarian-cli").resolve()
        if alt.exists():
            print(f"note: {binary} missing; using {alt} (pass --binary to override)", file=sys.stderr)
            binary = alt
        else:
            raise SystemExit(f"missing CLI binary: {binary} (and {alt} missing); build with `swift build`")
    temp = Path(tempfile.mkdtemp(prefix="private-librarian-bench-"))
    source = temp / "library"
    catalog = temp / "catalog.db"
    source.mkdir()
    generated_at = time.perf_counter()
    generate_library(source, args.files)
    generation_seconds = time.perf_counter() - generated_at
    fixture_bytes = sum(p.stat().st_size for p in source.rglob("*") if p.is_file())
    actual_files = sum(1 for _ in source.rglob("*") if _.is_file())
    warmup_ms: float | None = None
    if args.tier2:
        t0 = time.perf_counter()
        _ = time_search_loop(binary, catalog, "warmup-probe", iters=1, tier2=True)
        warmup_ms = (time.perf_counter() - t0) * 1000
    cold = run_cli(binary, catalog, ["index", str(source)], tier2=args.tier2)
    cold_db = catalog_stats(catalog)
    cold_counts = per_stage_counts_via_status(binary, catalog)
    cold_fps = (actual_files / cold["seconds"]) if cold["seconds"] > 0 else None
    warm = run_cli(binary, catalog, ["index", str(source)], tier2=args.tier2)
    warm_db = catalog_stats(catalog)
    warm_counts = per_stage_counts_via_status(binary, catalog)
    target = source / "CSC-151" / "unit-00" / "doc-000000.txt"
    if not target.exists():
        cands = sorted(source.rglob("doc-*.txt"))
        target = cands[0] if cands else target
    if target.exists():
        target.write_text(target.read_text(encoding="utf-8") + "changed-generation\n", encoding="utf-8")
    one_change = run_cli(binary, catalog, ["index", str(source)], tier2=args.tier2)
    one_counts = per_stage_counts_via_status(binary, catalog)
    dupes = run_cli(binary, catalog, ["dupes"], tier2=args.tier2)
    fts = time_search_loop(binary, catalog, "synthetic benchmark", iters=args.search_iters)
    relation_query = time_graph_loop(binary, catalog, iters=args.relation_iters)
    semantic = None
    clip_t2i = None
    if args.tier2:
        semantic = time_search_loop(binary, catalog, "assignment unit 00",
                                    iters=max(5, args.search_iters // 2), tier2=True)
        clip_t2i = time_search_loop(binary, catalog, "photo of a document",
                                    iters=max(5, args.search_iters // 2), tier2=True)
    final_db = catalog_stats(catalog)
    final_counts = per_stage_counts_via_status(binary, catalog)
    result = {
        "schema": 2,
        "files_requested": args.files,
        "files_actual": actual_files,
        "fixture_bytes": fixture_bytes,
        "generation_seconds": generation_seconds,
        "tier2_enabled": bool(args.tier2),
        "commit": repository_revision(),
        "binary": str(binary),
        "cold": {**cold, "files_per_sec": round(cold_fps, 1) if cold_fps else None, "db_size_bytes": cold_db["db_size_bytes"], "counts": cold_counts},
        "warm": {**warm, "db_size_bytes": warm_db["db_size_bytes"], "counts": warm_counts},
        "one_change": {**one_change, "counts": one_counts},
        "dupes": dupes,
        "search": {"fts": fts, "semantic": semantic, "clip_text_to_image": clip_t2i},
        "organization_graph": relation_query,
        "model_warmup_ms": round(warmup_ms, 1) if warmup_ms is not None else None,
        "final": {"db_size_bytes": final_db["db_size_bytes"], "counts": final_counts},
        "embedding_size_bytes": (final_counts or {}).get("embedding_bytes", 0),
        "embedding_chunk_size_bytes": (final_counts or {}).get("embedding_chunk_bytes", 0),
        "notes": "All fixtures synthetic under tempfile; no real user folders touched. 100k opt-in via --files 100000. Thresholds only after baseline; CI does not gate on timings.",
    }
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    def fmt(v, w=10):
        return ("—" if v is None else str(v)).rjust(w)
    print("")
    print(f"Benchmark — {args.files} files ({'Tier-2' if args.tier2 else 'Tier-1 only'})  binary={binary.name}")
    print("-" * 72)
    print(f"  {'stage':<18} {'seconds':>10} {'files/s':>10} {'rss MB':>8} {'indexed':>8} {'dupes':>6}")
    print(f"  {'cold index':<18} {fmt(round(cold['seconds'],3))} {fmt(round(cold_fps,1) if cold_fps else None)} {fmt(cold['rss_peak_mb'],8)} {fmt(cold['indexed'])} {fmt(cold['dupes_groups'],6)}")
    warm_fps = (actual_files / warm["seconds"]) if warm["seconds"] > 0 else None
    oc_fps = (actual_files / one_change["seconds"]) if one_change["seconds"] > 0 else None
    print(f"  {'warm re-scan':<18} {fmt(round(warm['seconds'],3))} {fmt(round(warm_fps,1) if warm_fps else None)} {fmt(warm['rss_peak_mb'],8)} {fmt(warm['indexed'])} {fmt(warm['dupes_groups'],6)}")
    print(f"  {'one-file change':<18} {fmt(round(one_change['seconds'],3))} {fmt(round(oc_fps,1) if oc_fps else None)} {fmt(one_change['rss_peak_mb'],8)} {fmt(one_change['indexed'])} {fmt(one_change['dupes_groups'],6)}")
    print(f"  {'dupes':<18} {fmt(round(dupes['seconds'],3))} {'—'.rjust(10)} {fmt(dupes['rss_peak_mb'],8)} {'—'.rjust(8)} {fmt(dupes['dupes_groups'],6)}")
    print(f"  {'FTS p50/p95':<18} {fmt(str(fts['p50_ms'])+'ms' if fts['p50_ms'] is not None else None,10)} {fmt(str(fts['p95_ms'])+'ms' if fts['p95_ms'] is not None else None,10)}")
    if semantic is not None:
        print(f"  {'semantic p50/p95':<18} {fmt(str(semantic['p50_ms'])+'ms' if semantic['p50_ms'] is not None else None,10)} {fmt(str(semantic['p95_ms'])+'ms' if semantic['p95_ms'] is not None else None,10)}")
    if clip_t2i is not None:
        print(f"  {'CLIP t→i p50/p95':<18} {fmt(str(clip_t2i['p50_ms'])+'ms' if clip_t2i['p50_ms'] is not None else None,10)} {fmt(str(clip_t2i['p95_ms'])+'ms' if clip_t2i['p95_ms'] is not None else None,10)}")
    print(f"  {'graph p50/p95':<18} {fmt(str(relation_query['p50_ms'])+'ms' if relation_query['p50_ms'] is not None else None,10)} {fmt(str(relation_query['p95_ms'])+'ms' if relation_query['p95_ms'] is not None else None,10)}")
    print(f"  DB size: {final_db['db_size_bytes']} bytes   fixture: {fixture_bytes} bytes   output: {args.output}")
    if warm["indexed"] == 0:
        print("  warm unchanged scan: near-zero expensive work ✓ (indexed 0)")
    else:
        print(f"  warm unchanged scan: indexed {warm['indexed']} (expected 0 for unchanged fixtures)")
    ok = all(x["returncode"] == 0 for x in (cold, warm, one_change, dupes, relation_query))
    if args.keep_fixture:
        print(f"fixture kept at {temp}")
    else:
        shutil.rmtree(temp, ignore_errors=True)
    return 0 if ok else 1

if __name__ == "__main__":
    raise SystemExit(main())
