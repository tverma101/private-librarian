#!/usr/bin/env python3
"""Synthetic benchmark harness for Private Librarian.

Never points at real user folders. Generates an isolated temporary library,
runs the existing CLI, and emits JSON suitable for comparing commits.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time


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

    # Exact duplicate candidates without making the whole corpus duplicate-heavy.
    if files >= 20:
        payload = b"private-librarian-benchmark-duplicate\n" * 128
        dup = root / "duplicates"
        dup.mkdir(parents=True, exist_ok=True)
        (dup / "copy-a.bin").write_bytes(payload)
        (dup / "copy-b.bin").write_bytes(payload)


def run_cli(binary: Path, catalog: Path, source: Path, command: list[str]) -> dict:
    env = dict(os.environ)
    env["LIBRARIAN_CATALOG_KEY"] = "benchmark-only-fixed-key-do-not-use-for-real-data"
    env["LIBRARIAN_CATALOG_PATH"] = str(catalog)
    started = time.perf_counter()
    proc = subprocess.run(
        [str(binary), *command],
        cwd=str(binary.parent),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    elapsed = time.perf_counter() - started
    return {
        "command": command,
        "seconds": elapsed,
        "returncode": proc.returncode,
        "stdout_tail": proc.stdout[-2000:],
        "stderr_tail": proc.stderr[-2000:],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--binary", type=Path, default=Path(".build/release/librarian-cli"))
    ap.add_argument("--files", type=int, default=10_000)
    ap.add_argument("--output", type=Path, default=Path("benchmark-result.json"))
    ap.add_argument("--keep-fixture", action="store_true")
    args = ap.parse_args()

    binary = args.binary.resolve()
    if not binary.exists():
        raise SystemExit(f"missing CLI binary: {binary}; build with `swift build -c release`")

    temp = Path(tempfile.mkdtemp(prefix="private-librarian-bench-"))
    source = temp / "library"
    catalog = temp / "catalog.db"
    source.mkdir()

    generated_at = time.perf_counter()
    generate_library(source, args.files)
    generation_seconds = time.perf_counter() - generated_at

    cold = run_cli(binary, catalog, source, ["index", str(source)])
    warm = run_cli(binary, catalog, source, ["index", str(source)])

    # Modify exactly one deterministic source and measure incremental work.
    target = source / "CSC-151" / "unit-00" / "doc-000000.txt"
    target.write_text(target.read_text() + "changed-generation\n", encoding="utf-8")
    one_change = run_cli(binary, catalog, source, ["index", str(source)])

    result = {
        "schema": 1,
        "files_requested": args.files,
        "generation_seconds": generation_seconds,
        "fixture_bytes": sum(p.stat().st_size for p in source.rglob("*") if p.is_file()),
        "cold": cold,
        "warm": warm,
        "one_change": one_change,
    }
    args.output.write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps({
        "files": args.files,
        "generate_s": round(generation_seconds, 3),
        "cold_s": round(cold["seconds"], 3),
        "warm_s": round(warm["seconds"], 3),
        "one_change_s": round(one_change["seconds"], 3),
        "output": str(args.output),
    }, indent=2))

    ok = all(x["returncode"] == 0 for x in (cold, warm, one_change))
    if args.keep_fixture:
        print(f"fixture kept at {temp}")
    else:
        shutil.rmtree(temp, ignore_errors=True)
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
