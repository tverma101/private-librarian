#!/usr/bin/env python3
"""Deterministic organization-quality metrics for Private Librarian.

This module is intentionally model-agnostic: agents can feed predictions from any
classifier/provider and compare commits without changing the metric definitions.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
from pathlib import Path
from typing import Iterable


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


def macro_f1(rows: list[dict], truth_key: str = "truth",
             prediction_key: str = "predicted") -> float:
    labels = {str(row.get(truth_key)) for row in rows} | {
        str(row.get(prediction_key)) for row in rows
    }
    labels.discard("None")
    if not labels:
        return 1.0
    scores = []
    for label in labels:
        tp = sum(1 for row in rows
                 if str(row.get(truth_key)) == label
                 and str(row.get(prediction_key)) == label)
        fp = sum(1 for row in rows
                 if str(row.get(truth_key)) != label
                 and str(row.get(prediction_key)) == label)
        fn = sum(1 for row in rows
                 if str(row.get(truth_key)) == label
                 and str(row.get(prediction_key)) != label)
        precision = tp / (tp + fp) if tp + fp else 1.0
        recall = tp / (tp + fn) if tp + fn else 1.0
        scores.append(
            2 * precision * recall / (precision + recall)
            if precision + recall else 0.0
        )
    return sum(scores) / len(scores)


def recall_at_k(rows: list[dict], relevant_key: str = "relevant", ranked_key: str = "ranked", k: int = 10) -> float:
    if not rows or k <= 0:
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


def cluster_completeness(assignments: list[dict]) -> float:
    """For each golden label, how often its members share one predicted cluster."""
    if not assignments:
        return 1.0
    labels: dict[str, dict[str, int]] = {}
    for row in assignments:
        label = str(row.get("label", ""))
        cluster = str(row.get("cluster", ""))
        counts = labels.setdefault(label, {})
        counts[cluster] = counts.get(cluster, 0) + 1
    scores = []
    for clusters in labels.values():
        total = sum(clusters.values())
        scores.append(max(clusters.values()) / total if total else 1.0)
    return sum(scores) / len(scores) if scores else 1.0


def pair_scores(rows: list[dict]) -> dict[str, float]:
    scores = [
        precision_recall_f1(row.get("truth", []), row.get("predicted", []))
        for row in rows
    ]
    if not scores:
        return {"precision": 1.0, "recall": 1.0, "f1": 1.0}
    return {
        key: sum(score[key] for score in scores) / len(scores)
        for key in ("precision", "recall", "f1")
    }


def mean_bool(rows: list[dict], key: str) -> float:
    if not rows:
        return 1.0
    return sum(1.0 for row in rows if bool(row.get(key))) / len(rows)


def mean_number(rows: list[dict], key: str) -> float | None:
    values = []
    for row in rows:
        try:
            value = float(row[key])
            if math.isfinite(value):
                values.append(value)
        except (KeyError, TypeError, ValueError):
            continue
    return sum(values) / len(values) if values else None


def correction_reduction(runs: list[dict]) -> float:
    if len(runs) < 2:
        return 0.0
    try:
        start = float(runs[0].get("manual_corrections", 0))
        end = float(runs[-1].get("manual_corrections", 0))
    except (TypeError, ValueError):
        return 0.0
    if not math.isfinite(start) or not math.isfinite(end):
        return 0.0
    return max(0.0, (start - end) / start) if start > 0 else 0.0


def evaluate(payload: dict) -> dict:
    screenshot_rows = payload.get("screenshots", [])
    screenshot_control_rows = payload.get("screenshot_controls", [])
    exact_rows = payload.get("exact_duplicates", payload.get("duplicates", []))
    near_rows = payload.get("near_duplicates", [])
    search_rows = payload.get("semantic_search", [])
    clusters = payload.get("clusters", [])
    exact_scores = pair_scores(exact_rows)
    near_scores = pair_scores(near_rows)
    ocr_rows = payload.get("ocr", [])
    classification_rows = payload.get(
        "course_topic_classification", payload.get("classification", [])
    )
    review_rows = payload.get("review", [])
    if isinstance(review_rows, dict):
        review_precision = float(review_rows.get("precision", 1.0))
        review_coverage = float(review_rows.get("coverage", 1.0))
    else:
        review_precision = mean_bool(review_rows, "correct")
        review_coverage = (
            sum(1.0 for row in review_rows if row.get("reviewed", True))
            / len(review_rows)
            if review_rows else 1.0
        )

    result = {
        "schema": 2,
        "golden_library": payload.get("golden_library", "synthetic-golden-v1"),
        "screenshot_subtype_accuracy": accuracy(screenshot_rows, "truth", "predicted"),
        "screenshot_subtype_macro_f1": macro_f1(screenshot_rows),
        "screenshot_control_accuracy": accuracy(
            screenshot_control_rows, "truth", "predicted"
        ),
        "exact_duplicate_precision": exact_scores["precision"],
        "exact_duplicate_recall": exact_scores["recall"],
        "exact_duplicate_f1": exact_scores["f1"],
        "near_duplicate_precision": near_scores["precision"],
        "near_duplicate_recall": near_scores["recall"],
        "near_duplicate_f1": near_scores["f1"],
        # Compatibility aliases for consumers of schema 1.
        "duplicate_precision": exact_scores["precision"],
        "duplicate_recall": exact_scores["recall"],
        "duplicate_f1": exact_scores["f1"],
        "semantic_recall_at_10": recall_at_k(search_rows, k=10),
        "cluster_purity": cluster_purity(clusters),
        "cluster_completeness": cluster_completeness(clusters),
        "ocr_recovery": mean_bool(ocr_rows, "recovered"),
        "ocr_latency_ms": mean_number(ocr_rows, "latency_ms"),
        "course_topic_accuracy": accuracy(
            classification_rows, "truth", "predicted"
        ),
        "review_precision": review_precision,
        "review_coverage": review_coverage,
        "correction_reduction": correction_reduction(
            payload.get("correction_runs", [])
        ),
        "identity": {
            "commit": payload.get("commit", "unknown"),
            "provider": payload.get("provider", "multi-provider-golden-fixture"),
            "model": payload.get("model", "provider-records"),
            "preprocessing": payload.get("preprocessing", "provider-records"),
        },
    }
    comparisons = []
    for provider in payload.get("providers", []):
        provider_commit = provider.get("commit", payload.get("commit", "unknown"))
        raw_quality_payload = provider.get("quality_payload", {})
        quality_payload = dict(raw_quality_payload) if isinstance(raw_quality_payload, dict) else {}
        quality_payload.setdefault("commit", provider_commit)
        quality_payload.setdefault("provider", provider.get("provider_id", "unknown"))
        quality_payload.setdefault("model", provider.get("model", "unknown"))
        quality_payload.setdefault("preprocessing", provider.get("preprocessing", "unknown"))
        comparisons.append({
            "provider_id": provider.get("provider_id", "unknown"),
            "commit": provider_commit,
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
            {"truth": "lms", "predicted": "lms"},
            {"truth": "receipt", "predicted": "receipt"},
            {"truth": "error", "predicted": "error"},
            {"truth": "conversation", "predicted": "conversation"},
            {"truth": "social", "predicted": "social"},
            {"truth": "map", "predicted": "school"},
            {"truth": "meme", "predicted": "meme"},
            {"truth": "reference", "predicted": "reference"},
            {"truth": "unknown", "predicted": "reference"},
        ],
        "screenshot_controls": [
            {"id": "plain-photo", "truth": "not-screenshot", "predicted": "not-screenshot"},
            {"id": "document-pdf", "truth": "not-screenshot", "predicted": "not-screenshot"},
        ],
        "exact_duplicates": [
            {"truth": ["a", "b", "c"], "predicted": ["a", "b", "c"]},
            {"truth": ["d", "e"], "predicted": ["d", "e"]},
        ],
        "near_duplicates": [
            {"truth": ["crop-a", "crop-b"], "predicted": ["crop-a", "crop-b", "lookalike"]},
        ],
        "semantic_search": [
            {"relevant": ["cat1", "cat2"], "ranked": ["cat1", "cat2", "dog1"]},
            {"relevant": ["code1"], "ranked": ["code1", "notes1"]},
        ],
        "clusters": [
            {"cluster": "c1", "label": "cats"},
            {"cluster": "c1", "label": "cats"},
            {"cluster": "c2", "label": "code"},
            {"cluster": "c3", "label": "code"},
        ],
        "ocr": [
            {"id": "receipt", "recovered": True, "latency_ms": 18.4},
            {"id": "scan", "recovered": False, "latency_ms": 41.8},
        ],
        "course_topic_classification": [
            {"truth": "CSC-151", "predicted": "CSC-151"},
            {"truth": "MAT-171", "predicted": "MAT-171"},
            {"truth": "ENG-112", "predicted": "CSC-151"},
        ],
        "review": [
            {"id": "ambiguous-1", "reviewed": True, "correct": True},
            {"id": "ambiguous-2", "reviewed": True, "correct": False},
        ],
        "correction_runs": [
            {"run": 1, "manual_corrections": 6},
            {"run": 2, "manual_corrections": 4},
            {"run": 3, "manual_corrections": 2},
        ],
    }
    return {
        **quality,
        "golden_library": "synthetic-golden-v1",
        "commit": None,
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
    ap.add_argument("--commit")
    ap.add_argument("--provider")
    ap.add_argument("--model")
    ap.add_argument("--preprocessing")
    args = ap.parse_args()

    payload = json.loads(args.input.read_text()) if args.input else built_in_fixture()
    if args.commit:
        payload["commit"] = args.commit
    if args.provider:
        payload["provider"] = args.provider
    if args.model:
        payload["model"] = args.model
    if args.preprocessing:
        payload["preprocessing"] = args.preprocessing
    if payload.get("commit") in (None, "unknown"):
        payload["commit"] = repository_revision()
    result = evaluate(payload)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
