#!/usr/bin/env python3
"""Train a compact exportable TF-IDF student from hard labels and soft teacher scores."""

from __future__ import annotations

import argparse
import fnmatch
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np

from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    DEFAULT_JSON,
    DEFAULT_REPORT,
    best_at_precision,
    config_name,
    export_model,
    fit_model,
    label_rows,
    load_corpora,
    make_model,
    metric_row,
    resolved_labels,
    scores_for,
)


REPO = Path(__file__).resolve().parents[2]
DEFAULT_DISTILLED_REPORT = REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student-report.md"
DEFAULT_DISTILLED_JSON = REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student.json"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def parse_float(value: Any) -> float | None:
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        return None
    if not np.isfinite(parsed):
        return None
    return parsed


def teacher_score_from_label(row: dict[str, Any]) -> float | None:
    probability = parse_float(row.get("wake_probability"))
    if probability is not None:
        return min(max(probability, 0.01), 0.99)
    if not isinstance(row.get("should_wake"), bool):
        return None
    confidence = parse_float(row.get("confidence"))
    if confidence is None:
        confidence = 0.8
    confidence = min(max(confidence, 0.5), 0.99)
    return confidence if bool(row["should_wake"]) else 1.0 - confidence


def load_teacher_scores(paths: list[Path], *, from_labels: bool) -> dict[str, float]:
    votes: dict[str, list[float]] = {}
    for path in paths:
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if not record_id or row.get("error"):
                continue
            if from_labels:
                score = teacher_score_from_label(row)
            else:
                score = parse_float(row.get("score") or row.get("teacher_score") or row.get("probability"))
            if score is None:
                continue
            votes.setdefault(str(record_id), []).append(min(max(score, 0.01), 0.99))
    return {record_id: float(sum(scores) / len(scores)) for record_id, scores in votes.items()}


def duplicate_soft_examples(
    corpus: dict[str, dict[str, Any]],
    teacher_scores: dict[str, float],
    *,
    exclude_ids: set[str],
    teacher_weight: float,
) -> tuple[list[dict[str, Any]], list[int], list[float]]:
    rows: list[dict[str, Any]] = []
    labels: list[int] = []
    weights: list[float] = []
    for record_id, score in sorted(teacher_scores.items()):
        if record_id in exclude_ids:
            continue
        record = corpus.get(record_id)
        if not record:
            continue
        positive_weight = max(0.0, teacher_weight * score)
        negative_weight = max(0.0, teacher_weight * (1.0 - score))
        if positive_weight > 0:
            rows.append(record)
            labels.append(1)
            weights.append(positive_weight)
        if negative_weight > 0:
            rows.append(record)
            labels.append(0)
            weights.append(negative_weight)
    return rows, labels, weights


def result_sort_key(result: dict[str, Any], precision_floor: float) -> tuple[float, float, float, float]:
    if float(result["precision"]) >= precision_floor:
        return (1.0, float(result["recall"]), float(result["precision"]), -float(result["wake_rate"]))
    return (0.0, float(result["precision"]), float(result["recall"]), -float(result["wake_rate"]))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--teacher-scores", type=Path, action="append", default=[])
    parser.add_argument("--teacher-labels", type=Path, action="append", default=[])
    parser.add_argument("--teacher-weight", type=float, default=0.10)
    parser.add_argument("--teacher-on-gold", action="store_true")
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--prefix-fields", default="source")
    parser.add_argument("--feature-sizes", default="30000,60000,90000")
    parser.add_argument("--c-values", default="0.5,1.0,2.0,4.0")
    parser.add_argument("--class-weights", default="none,balanced")
    parser.add_argument("--holdout-pattern", action="append", default=[])
    parser.add_argument("--json-output", type=Path, default=DEFAULT_DISTILLED_JSON)
    parser.add_argument("--report", type=Path, default=DEFAULT_DISTILLED_REPORT)
    args = parser.parse_args()

    if not args.holdout_pattern:
        raise SystemExit("Pass at least one --holdout-pattern so the student is evaluated on untouched labels")

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    label_ids = {str(row["record_id"]) for row in labels}
    holdout_label_rows = [
        row for row in labels if group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    holdout_ids = {str(row["record_id"]) for row in holdout_label_rows}
    train_label_rows = [
        row
        for row in labels
        if str(row["record_id"]) not in holdout_ids
        and not group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    if not holdout_label_rows:
        raise SystemExit("Holdout pattern produced no labels")

    train_labels = resolved_labels(train_label_rows)
    holdout_labels = resolved_labels(holdout_label_rows)
    train_rows: list[dict[str, Any]] = []
    train_y: list[int] = []
    for record_id, should_wake in train_labels.items():
        record = corpus.get(record_id)
        if record:
            train_rows.append(record)
            train_y.append(int(should_wake))
    holdout_rows: list[dict[str, Any]] = []
    holdout_y: list[int] = []
    for record_id, should_wake in holdout_labels.items():
        record = corpus.get(record_id)
        if record:
            holdout_rows.append(record)
            holdout_y.append(int(should_wake))
    if len(set(train_y)) < 2:
        raise SystemExit("Need both train classes")
    if not holdout_rows:
        raise SystemExit("No holdout corpus rows found")

    teacher_scores = load_teacher_scores(args.teacher_scores, from_labels=False)
    teacher_scores.update(load_teacher_scores(args.teacher_labels, from_labels=True))
    teacher_excludes = set(holdout_ids)
    if not args.teacher_on_gold:
        teacher_excludes.update(label_ids)
    teacher_rows, teacher_y, teacher_weights = duplicate_soft_examples(
        corpus,
        teacher_scores,
        exclude_ids=teacher_excludes,
        teacher_weight=args.teacher_weight,
    )

    prefix_fields = [field for field in args.prefix_fields.split(",") if field]
    feature_sizes = [int(value) for value in args.feature_sizes.split(",") if value]
    c_values = [float(value) for value in args.c_values.split(",") if value]
    class_weights = [None if value == "none" else value for value in args.class_weights.split(",") if value]

    y_holdout = np.array(holdout_y, dtype=np.int64)
    evaluated: list[dict[str, Any]] = []
    best: dict[str, Any] | None = None
    configs: list[dict[str, Any]] = []
    for feature_size in feature_sizes:
        for c_value in c_values:
            for class_weight in class_weights:
                configs.append(
                    {
                        "prefix_fields": prefix_fields,
                        "max_word_features": feature_size,
                        "max_char_features": feature_size,
                        "c_value": c_value,
                        "class_weight": class_weight,
                    }
                )

    combined_rows = train_rows + teacher_rows
    combined_y = train_y + teacher_y
    weights = [1.0] * len(train_rows) + teacher_weights

    for config in configs:
        model = make_model(**config)
        fit_model(model, combined_rows, combined_y, weights if teacher_rows else None)
        scores = scores_for(model, holdout_rows)
        selected = best_at_precision(y_holdout, scores, args.precision_floor)
        result = {
            "config": config,
            "name": config_name(config),
            "threshold": selected["threshold"],
            "precision": selected["precision"],
            "recall": selected["recall"],
            "wake_rate": selected["wake_rate"],
            "tp": selected["tp"],
            "fp": selected["fp"],
            "fn": selected["fn"],
            "tn": selected["tn"],
        }
        evaluated.append(result)
        if best is None or result_sort_key(result, args.precision_floor) > result_sort_key(best, args.precision_floor):
            best = result
        print(
            json.dumps(
                {
                    "candidate": result["name"],
                    "precision": result["precision"],
                    "recall": result["recall"],
                    "threshold": result["threshold"],
                },
                sort_keys=True,
            ),
            flush=True,
        )

    if best is None:
        raise SystemExit("No candidate evaluated")

    final_model = make_model(**best["config"])
    fit_model(final_model, combined_rows, combined_y, weights if teacher_rows else None)
    export_model(
        final_model,
        args.json_output,
        float(best["threshold"]),
        best["config"]["prefix_fields"],
        {
            "selected_threshold": best["threshold"],
            "precision_floor": args.precision_floor,
            "precision": best["precision"],
            "recall": best["recall"],
            "wake_rate": best["wake_rate"],
            "tp": best["tp"],
            "fp": best["fp"],
            "fn": best["fn"],
            "tn": best["tn"],
            "hard_train_rows": len(train_rows),
            "teacher_soft_rows": len(teacher_rows),
            "teacher_unique_scores": len(teacher_scores),
            "teacher_weight": args.teacher_weight,
            "teacher_on_gold": bool(args.teacher_on_gold),
            "config": best["config"],
        },
    )

    ranked = sorted(evaluated, key=lambda row: result_sort_key(row, args.precision_floor), reverse=True)
    lines = ["# Distilled TF-IDF Student Report", ""]
    lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Hard train rows: {len(train_rows)}")
    lines.append(f"Holdout rows: {len(holdout_rows)}")
    lines.append(f"Holdout wake labels: {sum(holdout_y)}")
    lines.append(f"Teacher unique scores: {len(teacher_scores)}")
    lines.append(f"Teacher soft duplicate rows: {len(teacher_rows)}")
    lines.append(f"Teacher weight: {args.teacher_weight:.3f}")
    lines.append(f"Teacher on gold: {bool(args.teacher_on_gold)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Selected: `{best['name']}`")
    lines.append(f"Selected threshold: {float(best['threshold']):.3f}")
    lines.append(f"Export JSON: {args.json_output}")
    lines.append("")
    lines.append("## Selected Holdout Metrics")
    lines.append("")
    lines.append("| precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(**best)
    )
    lines.append("")
    lines.append("## Top Candidates")
    lines.append("")
    lines.append("| rank | threshold | precision | recall | wake rate | config |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | --- |")
    for index, row in enumerate(ranked[:20], 1):
        lines.append(
            "| {rank} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | `{name}` |".format(
                rank=index,
                **row,
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
