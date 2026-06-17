#!/usr/bin/env python3
"""Evaluate an exported Introspect wake model against audit labels."""

from __future__ import annotations

import argparse
import importlib.util
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "exported-model-eval-report.md"
DEFAULT_MODEL = Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json"
HOOK_SCORER = REPO / "hooks" / "intent_classifier.py"


def load_scorer():
    spec = importlib.util.spec_from_file_location("intent_classifier", HOOK_SCORER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {HOOK_SCORER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def label_rows(audit_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            if row.get("record_id"):
                merged = dict(row)
                merged["label_file"] = path.name
                rows.append(merged)
    return rows


def resolved_labels(rows: list[dict[str, Any]]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for row in rows:
        votes.setdefault(str(row["record_id"]), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def metric_row(y_true: np.ndarray, scores: np.ndarray, threshold: float) -> dict[str, float | int]:
    pred = scores >= threshold
    tp = int(((pred == 1) & (y_true == 1)).sum())
    fp = int(((pred == 1) & (y_true == 0)).sum())
    fn = int(((pred == 0) & (y_true == 1)).sum())
    tn = int(((pred == 0) & (y_true == 0)).sum())
    return {
        "threshold": threshold,
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if len(y_true) else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def thresholds() -> list[float]:
    return [round(value / 100, 2) for value in range(20, 96, 5)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    scorer = load_scorer()
    model = scorer.load_model(str(args.model))
    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = resolved_labels(label_rows(args.audit_dir))

    rows: list[dict[str, Any]] = []
    y: list[int] = []
    scores: list[float] = []
    prefix_fields = model.get("text_prefix_fields")
    if not isinstance(prefix_fields, list):
        prefix_fields = None
    for record_id, should_wake in labels.items():
        row = corpus.get(record_id)
        if not row:
            continue
        text = scorer.classifier_text(
            row.get("text", ""),
            source=row.get("source") or "unknown",
            old_trigger=bool(row.get("old_trigger")),
            matched_words=row.get("matched_words") or [],
            prefix_fields=prefix_fields,
        )
        result = scorer.score_text(text, model)
        rows.append(row)
        y.append(int(should_wake))
        scores.append(float(result["score"]))

    y_array = np.array(y, dtype=np.int64)
    scores_array = np.array(scores, dtype=np.float64)
    lines = ["# Exported Model Eval Report", ""]
    lines.append(f"Model: {args.model}")
    lines.append(f"Model type: {model.get('model_type')}")
    lines.append(f"Model threshold: {float(model.get('threshold', 0.5)):.3f}")
    lines.append(f"Text prefix fields: {model.get('text_prefix_fields')}")
    lines.append(f"Rows: {len(y)}")
    lines.append(f"Positive wake labels: {int(y_array.sum())}")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in thresholds():
        metrics = metric_row(y_array, scores_array, row)
        lines.append(
            "| {threshold:.2f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **metrics
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
