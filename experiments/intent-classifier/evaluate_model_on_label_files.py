#!/usr/bin/env python3
"""Evaluate an exported Introspect wake model on selected label files."""

from __future__ import annotations

import argparse
import importlib.util
import json
from collections import Counter
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
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


def resolved_labels(paths: list[Path]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for path in paths:
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id:
                votes.setdefault(str(record_id), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def metric_row(y_true: list[int], scores: list[float], threshold: float) -> dict[str, float | int]:
    tp = fp = fn = tn = 0
    for truth, score in zip(y_true, scores):
        pred = score >= threshold
        if pred and truth:
            tp += 1
        elif pred and not truth:
            fp += 1
        elif not pred and truth:
            fn += 1
        else:
            tn += 1
    return {
        "threshold": threshold,
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if y_true else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def thresholds() -> list[float]:
    return [round(value / 1000, 3) for value in range(200, 951, 25)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--label-file", type=Path, action="append", required=True)
    args = parser.parse_args()

    scorer = load_scorer()
    model = scorer.load_model(str(args.model))
    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = resolved_labels(args.label_file)
    prefix_fields = model.get("text_prefix_fields")
    if not isinstance(prefix_fields, list):
        prefix_fields = None

    rows: list[dict[str, Any]] = []
    y: list[int] = []
    scores: list[float] = []
    missing = 0
    for record_id, should_wake in labels.items():
        row = corpus.get(record_id)
        if not row:
            missing += 1
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

    production_threshold = float(model.get("threshold", 0.5))
    lines = ["# Label File Holdout Eval", ""]
    lines.append(f"Model: {args.model}")
    lines.append(f"Model type: {model.get('model_type')}")
    lines.append(f"Production threshold: {production_threshold:.3f}")
    lines.append(f"Label files: {', '.join(path.name for path in args.label_file)}")
    lines.append(f"Rows: {len(y)}")
    lines.append(f"Missing corpus rows: {missing}")
    lines.append(f"Positive wake labels: {sum(y)}")
    lines.append("")
    lines.append("## Metrics")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    metric_thresholds = sorted({production_threshold, *thresholds()})
    for threshold in metric_thresholds:
        metrics = metric_row(y, scores, threshold)
        lines.append(
            "| {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **metrics
            )
        )
    lines.append("")
    lines.append("## Misses At Production Threshold")
    lines.append("")
    misses = [
        (float(score), row)
        for score, row, truth in zip(scores, rows, y)
        if truth and score < production_threshold
    ]
    if not misses:
        lines.append("None.")
    else:
        lines.append("| score | id | source | text |")
        lines.append("| ---: | --- | --- | --- |")
        for score, row in sorted(misses, key=lambda item: item[0], reverse=True)[:40]:
            text = " ".join(str(row.get("text", "")).split())[:180].replace("|", "\\|")
            lines.append(f"| {score:.3f} | `{row.get('id')}` | {row.get('source') or ''} | {text} |")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
