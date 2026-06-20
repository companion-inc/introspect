#!/usr/bin/env python3
"""Train/evaluate an exportable two-stage wake gate.

The first stage is an existing exported wake scorer run at a lower threshold.
The second stage is a trained text gate that must also agree before waking.
"""

from __future__ import annotations

import argparse
import fnmatch
import importlib.util
import json
import sys
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "experiments" / "intent-classifier"))

from train_intent_v2_grid import (  # noqa: E402
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    config_name,
    export_model,
    load_corpora,
    make_model,
    metric_row,
    read_jsonl,
    resolved_labels,
    result_sort_key,
    scores_for,
    text_features,
)


HOOK_SCORER = REPO / "hooks" / "intent_classifier.py"
DEFAULT_BASE_MODEL = Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "two-stage-gate-round8-report.md"
DEFAULT_GATE_JSON = REPO / "feedback" / "intent-classifier" / "two-stage-gate-round8-gate.json"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "two-stage-gate-round8-scores.jsonl"


def load_scorer():
    spec = importlib.util.spec_from_file_location("intent_classifier", HOOK_SCORER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {HOOK_SCORER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def label_rows(audit_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            if not row.get("record_id") or not isinstance(row.get("should_wake"), bool):
                continue
            merged = dict(row)
            merged["label_file"] = path.name
            rows.append(merged)
    return rows


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def rows_for_resolved(corpus: dict[str, dict[str, Any]], labels: dict[str, bool]) -> tuple[list[str], list[dict[str, Any]], np.ndarray]:
    ids: list[str] = []
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, should_wake in sorted(labels.items()):
        row = corpus.get(record_id)
        if not row:
            continue
        ids.append(record_id)
        rows.append(row)
        y.append(int(should_wake))
    return ids, rows, np.array(y, dtype=np.int64)


def base_scores_for(rows: list[dict[str, Any]], base_model_path: Path) -> np.ndarray:
    scorer = load_scorer()
    base_model = scorer.load_model(str(base_model_path))
    prefix_fields = base_model.get("text_prefix_fields")
    if not isinstance(prefix_fields, list):
        prefix_fields = None
    values: list[float] = []
    for row in rows:
        text = scorer.classifier_text(
            row.get("text", ""),
            source=row.get("source") or "unknown",
            old_trigger=bool(row.get("old_trigger")),
            matched_words=row.get("matched_words") or [],
            prefix_fields=prefix_fields,
        )
        values.append(float(scorer.score_text(text, base_model)["score"]))
    return np.array(values, dtype=np.float64)


def threshold_grid(start: int = 50, stop: int = 950, step: int = 5) -> list[float]:
    return [round(value / 1000, 3) for value in range(start, stop + 1, step)]


def two_stage_metric(
    y_true: np.ndarray,
    base_scores: np.ndarray,
    gate_scores: np.ndarray,
    base_threshold: float,
    gate_threshold: float,
) -> dict[str, float | int]:
    combined = np.minimum(base_scores, gate_scores)
    pred = (base_scores >= base_threshold) & (gate_scores >= gate_threshold)
    tp = int(((pred == 1) & (y_true == 1)).sum())
    fp = int(((pred == 1) & (y_true == 0)).sum())
    fn = int(((pred == 0) & (y_true == 1)).sum())
    tn = int(((pred == 0) & (y_true == 0)).sum())
    return {
        "base_threshold": base_threshold,
        "gate_threshold": gate_threshold,
        "threshold": min(base_threshold, gate_threshold),
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if len(y_true) else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
        "combined_min_score": float(combined.mean()) if len(combined) else 0.0,
    }


def best_two_stage(
    y_true: np.ndarray,
    base_scores: np.ndarray,
    gate_scores: np.ndarray,
    precision_floor: float,
    base_thresholds: list[float],
    gate_thresholds: list[float],
) -> dict[str, float | int]:
    rows = [
        two_stage_metric(y_true, base_scores, gate_scores, base_threshold, gate_threshold)
        for base_threshold in base_thresholds
        for gate_threshold in gate_thresholds
    ]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if viable:
        return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))
    return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"]), -float(row["wake_rate"])))


def write_scores(
    path: Path,
    ids: list[str],
    rows: list[dict[str, Any]],
    y: np.ndarray,
    base_scores: np.ndarray,
    gate_scores: np.ndarray,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for record_id, row, truth, base_score, gate_score in zip(ids, rows, y, base_scores, gate_scores):
            handle.write(
                json.dumps(
                    {
                        "record_id": record_id,
                        "source": row.get("source"),
                        "label": int(truth),
                        "base_score": float(base_score),
                        "gate_score": float(gate_score),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--base-model", type=Path, default=DEFAULT_BASE_MODEL)
    parser.add_argument("--holdout-pattern", action="append", default=None)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--prefix-fields", default="source")
    parser.add_argument("--feature-sizes", default="60000,90000,120000")
    parser.add_argument("--c-values", default="0.5,1.0,2.0,4.0")
    parser.add_argument("--class-weights", default="none,balanced")
    parser.add_argument("--base-thresholds", default="0.200,0.250,0.300,0.350,0.400,0.450,0.500,0.550,0.600,0.650,0.675")
    parser.add_argument("--gate-threshold-start", type=int, default=50)
    parser.add_argument("--gate-threshold-stop", type=int, default=950)
    parser.add_argument("--gate-threshold-step", type=int, default=5)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--gate-json-output", type=Path, default=DEFAULT_GATE_JSON)
    parser.add_argument("--scores-output", type=Path, default=DEFAULT_SCORES)
    args = parser.parse_args()
    if args.holdout_pattern is None:
        args.holdout_pattern = ["*round8*.jsonl"]

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    train_label_rows = [
        row for row in labels
        if not group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    holdout_label_rows = [
        row for row in labels
        if group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    train_labels = resolved_labels(train_label_rows)
    holdout_labels = resolved_labels(holdout_label_rows)
    _, train_rows, train_y = rows_for_resolved(corpus, train_labels)
    holdout_ids, holdout_rows, holdout_y = rows_for_resolved(corpus, holdout_labels)
    if len(set(train_y.tolist())) < 2 or len(set(holdout_y.tolist())) < 2:
        raise SystemExit("Need both classes in train and holdout")

    holdout_base_scores = base_scores_for(holdout_rows, args.base_model)
    base_thresholds = [float(value) for value in args.base_thresholds.split(",") if value]
    gate_thresholds = threshold_grid(args.gate_threshold_start, args.gate_threshold_stop, args.gate_threshold_step)
    prefix_fields = [field for field in args.prefix_fields.split(",") if field]
    feature_sizes = [int(value) for value in args.feature_sizes.split(",") if value]
    c_values = [float(value) for value in args.c_values.split(",") if value]
    class_weights = [None if value == "none" else value for value in args.class_weights.split(",") if value]

    evaluated: list[dict[str, Any]] = []
    best: dict[str, Any] | None = None
    best_model: Any = None
    best_gate_scores: np.ndarray | None = None
    for feature_size in feature_sizes:
        for c_value in c_values:
            for class_weight in class_weights:
                config = {
                    "prefix_fields": prefix_fields,
                    "max_word_features": feature_size,
                    "max_char_features": feature_size,
                    "c_value": c_value,
                    "class_weight": class_weight,
                }
                model = make_model(**config)
                model.fit(train_rows, train_y)
                gate_scores = scores_for(model, holdout_rows)
                selected = best_two_stage(
                    holdout_y,
                    holdout_base_scores,
                    gate_scores,
                    args.precision_floor,
                    base_thresholds,
                    gate_thresholds,
                )
                result = {
                    "config": config,
                    "name": config_name(config),
                    **selected,
                    "evaluated_labels": len(holdout_y),
                    "positive_labels": int(holdout_y.sum()),
                }
                evaluated.append(result)
                print(
                    json.dumps(
                        {
                            "candidate": result["name"],
                            "base_threshold": result["base_threshold"],
                            "gate_threshold": result["gate_threshold"],
                            "precision": result["precision"],
                            "recall": result["recall"],
                        },
                        sort_keys=True,
                    ),
                    flush=True,
                )
                if best is None or result_sort_key(result, args.precision_floor) > result_sort_key(best, args.precision_floor):
                    best = result
                    best_model = model
                    best_gate_scores = gate_scores

    if best is None or best_model is None or best_gate_scores is None:
        raise SystemExit("No two-stage candidate evaluated")

    baseline = metric_row(holdout_y, holdout_base_scores, 0.675)
    write_scores(args.scores_output, holdout_ids, holdout_rows, holdout_y, holdout_base_scores, best_gate_scores)
    report_obj = {
        "selected_base_threshold": best["base_threshold"],
        "selected_gate_threshold": best["gate_threshold"],
        "precision_floor": args.precision_floor,
        "precision": best["precision"],
        "recall": best["recall"],
        "wake_rate": best["wake_rate"],
        "tp": best["tp"],
        "fp": best["fp"],
        "fn": best["fn"],
        "tn": best["tn"],
        "base_model": str(args.base_model),
        "train_rows": len(train_y),
        "holdout_rows": len(holdout_y),
        "config": best["config"],
    }
    export_model(
        best_model,
        args.gate_json_output,
        float(best["gate_threshold"]),
        best["config"]["prefix_fields"],
        report_obj,
    )

    ranked = sorted(evaluated, key=lambda row: result_sort_key(row, args.precision_floor), reverse=True)
    lines = ["# Two-Stage Gate Report", ""]
    lines.append(f"Base model: `{args.base_model}`")
    lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Train rows: {len(train_y)}")
    lines.append(f"Holdout rows: {len(holdout_y)}")
    lines.append(f"Holdout wake labels: {int(holdout_y.sum())}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Selected gate: `{best['name']}`")
    lines.append(f"Selected base threshold: {float(best['base_threshold']):.3f}")
    lines.append(f"Selected gate threshold: {float(best['gate_threshold']):.3f}")
    lines.append(f"Gate JSON: `{args.gate_json_output}`")
    lines.append("")
    lines.append("## Baseline")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **baseline
        )
    )
    lines.append("")
    lines.append("## Selected Holdout Metric")
    lines.append("")
    lines.append("| base threshold | gate threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {base_threshold:.3f} | {gate_threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **best
        )
    )
    lines.append("")
    lines.append("## Top Candidates")
    lines.append("")
    lines.append("| rank | base threshold | gate threshold | precision | recall | wake rate | config |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for index, row in enumerate(ranked[:20], 1):
        lines.append(
            "| {rank} | {base_threshold:.3f} | {gate_threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | `{name}` |".format(
                rank=index,
                **row,
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
