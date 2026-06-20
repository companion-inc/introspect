#!/usr/bin/env python3
"""Evaluate a fold-trained hard+distilled AND ensemble for wake intent."""

from __future__ import annotations

import argparse
import fnmatch
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np

from train_distilled_tfidf_student import duplicate_soft_examples, load_teacher_scores
from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    fit_model,
    label_rows,
    load_corpora,
    make_model,
    resolved_labels,
    scores_for,
)


REPO = Path(__file__).resolve().parents[2]
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "fold-trained-and-ensemble-report.md"
DEFAULT_TEACHER_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full-v2-resume.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
    REPO / "feedback" / "intent-classifier" / "hf-agent-trace-qwen-labels.jsonl",
]
DEFAULT_GROUPS = [
    ("round4", "*round4*.jsonl"),
    ("round5", "*round5*.jsonl"),
    ("round6", "*round6*.jsonl"),
    ("round7", "*round7*.jsonl"),
    ("round8", "*round8*.jsonl"),
    ("round9", "*round9*.jsonl"),
]


def metric(y_true: np.ndarray, pred: np.ndarray) -> dict[str, float | int]:
    tp = int(((pred == 1) & (y_true == 1)).sum())
    fp = int(((pred == 1) & (y_true == 0)).sum())
    fn = int(((pred == 0) & (y_true == 1)).sum())
    tn = int(((pred == 0) & (y_true == 0)).sum())
    return {
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if len(y_true) else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def threshold_grid() -> list[float]:
    return [round(value / 1000, 3) for value in range(200, 951, 25)]


def best_and_thresholds(
    y_true: np.ndarray,
    hard_scores: np.ndarray,
    distilled_scores: np.ndarray,
    precision_floor: float,
) -> tuple[float, float, dict[str, float | int]]:
    best: tuple[float, float, dict[str, float | int]] | None = None
    for hard_threshold in threshold_grid():
        hard_pred = hard_scores >= hard_threshold
        for distilled_threshold in threshold_grid():
            pred = hard_pred & (distilled_scores >= distilled_threshold)
            row = metric(y_true, pred)
            if best is None or sort_key(row, precision_floor) > sort_key(best[2], precision_floor):
                best = (hard_threshold, distilled_threshold, row)
    if best is None:
        raise RuntimeError("No threshold pair evaluated")
    return best


def sort_key(row: dict[str, Any], precision_floor: float) -> tuple[float, float, float, float]:
    if float(row["precision"]) >= precision_floor:
        return (1.0, float(row["recall"]), float(row["precision"]), -float(row["wake_rate"]))
    return (0.0, float(row["precision"]), float(row["recall"]), -float(row["wake_rate"]))


def parse_group(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        return raw, raw
    name, pattern = raw.split("=", 1)
    return name, pattern


def rows_for_labels(corpus: dict[str, dict[str, Any]], labels: dict[str, bool]) -> tuple[list[dict[str, Any]], list[int]]:
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, should_wake in labels.items():
        record = corpus.get(record_id)
        if record:
            rows.append(record)
            y.append(int(should_wake))
    return rows, y


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--teacher-labels", type=Path, action="append", default=DEFAULT_TEACHER_LABELS)
    parser.add_argument("--teacher-weight", type=float, default=0.05)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--feature-size", type=int, default=60000)
    parser.add_argument("--c-value", type=float, default=4.0)
    parser.add_argument("--group", action="append", default=[])
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    label_ids = {str(row["record_id"]) for row in labels}
    group_specs = [parse_group(raw) for raw in args.group] or DEFAULT_GROUPS
    teacher_scores = load_teacher_scores(args.teacher_labels, from_labels=True)
    teacher_rows, teacher_y, teacher_weights = duplicate_soft_examples(
        corpus,
        teacher_scores,
        exclude_ids=label_ids,
        teacher_weight=args.teacher_weight,
    )
    config = {
        "prefix_fields": ["source"],
        "max_word_features": args.feature_size,
        "max_char_features": args.feature_size,
        "c_value": args.c_value,
        "class_weight": None,
    }

    fold_rows: list[dict[str, Any]] = []
    aggregate_y: list[int] = []
    aggregate_pred: list[bool] = []
    for group_name, pattern in group_specs:
        test_label_rows = [row for row in labels if fnmatch.fnmatch(str(row["label_file"]), pattern)]
        test_ids = {str(row["record_id"]) for row in test_label_rows}
        train_label_rows = [row for row in labels if str(row["record_id"]) not in test_ids]
        train_rows, train_y = rows_for_labels(corpus, resolved_labels(train_label_rows))
        test_rows, test_y = rows_for_labels(corpus, resolved_labels(test_label_rows))
        if len(set(train_y)) < 2 or not test_rows:
            continue

        hard_model = make_model(**config)
        fit_model(hard_model, train_rows, train_y, None)
        distilled_model = make_model(**config)
        combined_rows = train_rows + teacher_rows
        combined_y = train_y + teacher_y
        weights = [1.0] * len(train_rows) + teacher_weights
        fit_model(distilled_model, combined_rows, combined_y, weights)

        train_hard_scores = scores_for(hard_model, train_rows)
        train_distilled_scores = scores_for(distilled_model, train_rows)
        test_hard_scores = scores_for(hard_model, test_rows)
        test_distilled_scores = scores_for(distilled_model, test_rows)
        y_train = np.array(train_y, dtype=np.int64)
        y_test = np.array(test_y, dtype=np.int64)
        hard_threshold, distilled_threshold, train_metric = best_and_thresholds(
            y_train,
            train_hard_scores,
            train_distilled_scores,
            args.precision_floor,
        )
        pred_test = (test_hard_scores >= hard_threshold) & (test_distilled_scores >= distilled_threshold)
        test_metric = metric(y_test, pred_test)
        aggregate_y.extend(test_y)
        aggregate_pred.extend(map(bool, pred_test))
        fold_rows.append(
            {
                "group": group_name,
                "hard_threshold": hard_threshold,
                "distilled_threshold": distilled_threshold,
                "train": train_metric,
                "test": test_metric,
            }
        )
        print(
            json.dumps(
                {
                    "group": group_name,
                    "hard_threshold": hard_threshold,
                    "distilled_threshold": distilled_threshold,
                    "train_precision": train_metric["precision"],
                    "train_recall": train_metric["recall"],
                    "test_precision": test_metric["precision"],
                    "test_recall": test_metric["recall"],
                },
                sort_keys=True,
            ),
            flush=True,
        )

    y_all = np.array(aggregate_y, dtype=np.int64)
    pred_all = np.array(aggregate_pred, dtype=bool)
    aggregate = metric(y_all, pred_all)

    lines = ["# Fold-Trained AND Ensemble Report", ""]
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Feature size: {args.feature_size}")
    lines.append(f"C value: {args.c_value:.3f}")
    lines.append(f"Teacher scores: {len(teacher_scores)}")
    lines.append(f"Teacher duplicate rows: {len(teacher_rows)}")
    lines.append(f"Teacher weight: {args.teacher_weight:.3f}")
    lines.append("")
    lines.append("## Holdout")
    lines.append("")
    lines.append("| metric | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| loro selected | 0.000 | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **aggregate
        )
    )
    lines.append("")
    lines.append("## Folds")
    lines.append("")
    lines.append("| held-out group | hard threshold | distilled threshold | train precision | train recall | test precision | test recall | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in fold_rows:
        train = row["train"]
        test = row["test"]
        lines.append(
            "| {group} | {hard_threshold:.3f} | {distilled_threshold:.3f} | {train_precision:.4f} | {train_recall:.4f} | {test_precision:.4f} | {test_recall:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                group=row["group"],
                hard_threshold=row["hard_threshold"],
                distilled_threshold=row["distilled_threshold"],
                train_precision=float(train["precision"]),
                train_recall=float(train["recall"]),
                test_precision=float(test["precision"]),
                test_recall=float(test["recall"]),
                tp=int(test["tp"]),
                fp=int(test["fp"]),
                fn=int(test["fn"]),
                tn=int(test["tn"]),
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
