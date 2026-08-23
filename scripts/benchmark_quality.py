#!/usr/bin/env python3
"""Deterministic organization-quality metrics for Private Librarian.

This module is intentionally model-agnostic: agents can feed predictions from any
classifier/provider and compare commits without changing the metric definitions.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable


def precision_recall_f1(truth: Iterable[str], predicted: Iterable[str]) -> dict[str, float]:
    t = set(truth)
    p = set(predicted)
    tp = len(t & p)
    fp = len(p - t)
    fn = len(t - p)
    precision = tp / (tp + fp) if tp + fp else 1.0
    recall = tp / (tp + fn) if tp + fn else 1.0
    f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
    return {"precision": precision, "recall": recall, "f1": f1}


def accuracy(rows: list[dict], truth_key: str, prediction_key: str) -> float:
    if not rows:
        return 1.0
    correct = sum(1 for row in rows if row.get(truth_key) == row.get(prediction_key))
    return correct / len(rows)


def recall_at_k(rows: list[dict], relevant_key: str = "relevant", ranked_key: str = "ranked", k: int = 10) -> float:
    if not rows:
        return 1.0
    scores = []
    for row in rows:
        relevant = set(row.get(relevant_key, []))
        ranked = row.get(ranked_key, [])[:k]
        if not relevant:
            scores.append(1.0)
        else:
            scores.append(len(relevant.intersection(ranked)) / len(relevant))
    return sum(scores) / len(scores)


def cluster_purity(assignments: list[dict]) -> float:
    """Each row: {cluster: id, label: golden semantic label}."""
    if not assignments:
        return 1.0
    groups: dict[str, list[str]] = {}
    for row in assignments:
        groups.setdefault(str(row["cluster"]), []).append(str(row["label"]))
    correct = 0
    total = 0
    for labels in groups.values():
        counts: dict[str, int] = {}
        for label in labels:
            counts[label] = counts.get(label, 0) + 1
        correct += max(counts.values())
        total += len(labels)
    return correct / total if total else 1.0


def evaluate(payload: dict) -> dict:
    screenshot_rows = payload.get("screenshots", [])
    duplicate_rows = payload.get("duplicates", [])
    search_rows = payload.get("semantic_search", [])
    clusters = payload.get("clusters", [])

    duplicate_scores = [
        precision_recall_f1(row.get("truth", []), row.get("predicted", []))
        for row in duplicate_rows
    ]

    def mean(key: str, rows: list[dict]) -> float:
        return sum(r[key] for r in rows) / len(rows) if rows else 1.0

    result = {
        "schema": 1,
        "golden_library": payload.get("golden_library", "synthetic-golden-v1"),
        "screenshot_subtype_accuracy": accuracy(screenshot_rows, "truth", "predicted"),
        "duplicate_precision": mean("precision", duplicate_scores),
        "duplicate_recall": mean("recall", duplicate_scores),
        "duplicate_f1": mean("f1", duplicate_scores),
        "semantic_recall_at_10": recall_at_k(search_rows, k=10),
        "cluster_purity": cluster_purity(clusters),
    }
    comparisons = []
    for provider in payload.get("providers", []):
        quality_payload = provider.get("quality_payload", {})
        comparisons.append({
            "provider_id": provider.get("provider_id", "unknown"),
            "model": provider.get("model", "unknown"),
            "preprocessing": provider.get("preprocessing", "unknown"),
            "runtime": provider.get("runtime", {}),
            "quality": evaluate(quality_payload),
        })
    if comparisons:
        result["provider_comparisons"] = comparisons
    return result


def built_in_fixture() -> dict:
    quality = {
        "screenshots": [
            {"truth": "code", "predicted": "code"},
            {"truth": "school", "predicted": "school"},
            {"truth": "receipt", "predicted": "receipt"},
            {"truth": "map", "predicted": "map"},
        ],
        "duplicates": [
            {"truth": ["a", "b", "c"], "predicted": ["a", "b", "c"]},
            {"truth": ["d", "e"], "predicted": ["d", "e"]},
        ],
        "semantic_search": [
            {"relevant": ["cat1", "cat2"], "ranked": ["cat1", "cat2", "dog1"]},
            {"relevant": ["code1"], "ranked": ["code1", "notes1"]},
        ],
        "clusters": [
            {"cluster": "c1", "label": "cats"},
            {"cluster": "c1", "label": "cats"},
            {"cluster": "c2", "label": "code"},
            {"cluster": "c2", "label": "code"},
        ],
    }
    return {
        **quality,
        "golden_library": "synthetic-golden-v1",
        "providers": [
            {
                "provider_id": "python-transformers",
                "model": "clip-vit-base-patch32 + all-MiniLM-L6-v2",
                "preprocessing": "resize224-centerCrop-normalize;truncate4000-normalize",
                "runtime": {"status": "fixture-only", "warm_calls": 0},
                "quality_payload": quality,
            },
            {
                "provider_id": "fileid-openclip-compat",
                "model": "openai/clip-vit-base-patch32@3d74acf9",
                "preprocessing": "resize224-centerCrop-normalize",
                "runtime": {"status": "fixture-only", "warm_calls": 0},
                "quality_payload": quality,
            },
            {
                "provider_id": "apple-coreml-mobileclip",
                "model": "apple/coreml-mobileclip@3e0a7bfb",
                "preprocessing": "CoreML-256x256-ARGB-tokenBPE77",
                "runtime": {"status": "unavailable", "reason": "No artifact-backed runtime fixture supplied", "warm_calls": 0},
                "quality_payload": quality,
            },
        ],
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", type=Path)
    ap.add_argument("--output", type=Path, default=Path("quality-result.json"))
    args = ap.parse_args()

    payload = json.loads(args.input.read_text()) if args.input else built_in_fixture()
    result = evaluate(payload)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
