#!/usr/bin/env python3
"""Evaluate a non-lexical score ensemble for Introspect wake intent labels."""

from __future__ import annotations

import argparse
import fnmatch
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression

from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    best_at_precision,
    config_name,
    fit_model,
    label_rows,
    load_corpora,
    make_model,
    metric_row,
    resolved_labels,
    scores_for,
    threshold_grid,
)


REPO = Path(__file__).resolve().parents[2]
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "score-ensemble-round7-report.md"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "score-ensemble-round7-scores.jsonl"


BASE_CONFIGS: list[dict[str, Any]] = [
    {
        "prefix_fields": ["source"],
        "max_word_features": 90000,
        "max_char_features": 90000,
        "c_value": 4.0,
        "class_weight": None,
    },
    {
        "prefix_fields": ["source"],
        "max_word_features": 60000,
        "max_char_features": 60000,
        "c_value": 4.0,
        "class_weight": "balanced",
    },
]


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def rows_for_labels(
    corpus: dict[str, dict[str, Any]],
    labels: dict[str, bool],
) -> tuple[list[str], list[dict[str, Any]], list[int]]:
    ids: list[str] = []
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, should_wake in sorted(labels.items()):
        record = corpus.get(record_id)
        if not record:
            continue
        ids.append(record_id)
        rows.append(record)
        y.append(int(should_wake))
    return ids, rows, y


def features_from_scores(score_columns: list[np.ndarray]) -> np.ndarray:
    stacked = np.column_stack(score_columns)
    minimum = stacked.min(axis=1, keepdims=True)
    maximum = stacked.max(axis=1, keepdims=True)
    mean = stacked.mean(axis=1, keepdims=True)
    spread = maximum - minimum
    return np.hstack([stacked, minimum, maximum, mean, spread])


def fit_base_scores(
    corpus: dict[str, dict[str, Any]],
    train_labels: dict[str, bool],
    score_rows: list[dict[str, Any]],
) -> list[np.ndarray]:
    _, train_rows, train_y = rows_for_labels(corpus, train_labels)
    if len(set(train_y)) < 2:
        raise RuntimeError("Need both train classes")
    columns: list[np.ndarray] = []
    for config in BASE_CONFIGS:
        model = make_model(**config)
        fit_model(model, train_rows, train_y, None)
        columns.append(scores_for(model, score_rows))
    return columns


def best_row_for_scores(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if viable:
        return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))
    return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"]), -float(row["wake_rate"])))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--holdout-pattern", action="append", default=None)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--scores-output", type=Path, default=DEFAULT_SCORES)
    args = parser.parse_args()
    if args.holdout_pattern is None:
        args.holdout_pattern = ["*round7*.jsonl"]

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    holdout_label_rows = [
        row for row in labels if group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    train_label_rows = [
        row for row in labels if not group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    if not holdout_label_rows:
        raise SystemExit("Holdout pattern produced no labels")

    train_groups = sorted({str(row["label_file"]) for row in train_label_rows})
    holdout_labels = resolved_labels(holdout_label_rows)
    train_labels_all = resolved_labels(train_label_rows)
    holdout_ids, holdout_rows, holdout_y = rows_for_labels(corpus, holdout_labels)
    holdout_y_array = np.array(holdout_y, dtype=np.int64)

    oof_ids: list[str] = []
    oof_y: list[int] = []
    oof_columns: list[list[float]] = [[] for _ in BASE_CONFIGS]
    group_summaries: list[tuple[str, int, int]] = []

    for group in train_groups:
        test_rows_raw = [row for row in train_label_rows if str(row["label_file"]) == group]
        test_ids = {str(row["record_id"]) for row in test_rows_raw}
        train_rows_raw = [row for row in train_label_rows if str(row["record_id"]) not in test_ids]
        train_labels = resolved_labels(train_rows_raw)
        test_labels = resolved_labels(test_rows_raw)
        ids, score_rows, y = rows_for_labels(corpus, test_labels)
        if not score_rows or len(set(train_labels.values())) < 2:
            continue
        columns = fit_base_scores(corpus, train_labels, score_rows)
        for index, column in enumerate(columns):
            oof_columns[index].extend(map(float, column))
        oof_ids.extend(ids)
        oof_y.extend(y)
        group_summaries.append((group, len(y), sum(y)))
        print(json.dumps({"group": group, "rows": len(y), "wake": sum(y)}), flush=True)

    if not oof_y:
        raise SystemExit("No out-of-fold scores generated")

    oof_y_array = np.array(oof_y, dtype=np.int64)
    oof_score_arrays = [np.array(column, dtype=np.float64) for column in oof_columns]
    oof_features = features_from_scores(oof_score_arrays)
    meta = LogisticRegression(max_iter=5000, class_weight="balanced", solver="liblinear", C=1.0, random_state=42)
    meta.fit(oof_features, oof_y_array)
    oof_meta_scores = meta.predict_proba(oof_features)[:, 1]
    selected = best_row_for_scores(oof_y_array, oof_meta_scores, args.precision_floor)

    final_columns = fit_base_scores(corpus, train_labels_all, holdout_rows)
    holdout_features = features_from_scores(final_columns)
    holdout_meta_scores = meta.predict_proba(holdout_features)[:, 1]
    holdout_at_selected = metric_row(holdout_y_array, holdout_meta_scores, float(selected["threshold"]))
    holdout_best = best_row_for_scores(holdout_y_array, holdout_meta_scores, args.precision_floor)

    baseline_rows: list[dict[str, Any]] = []
    for name, scores in [
        ("meta", holdout_meta_scores),
        ("base0", final_columns[0]),
        ("base1", final_columns[1]),
        ("min", holdout_features[:, len(BASE_CONFIGS)]),
        ("max", holdout_features[:, len(BASE_CONFIGS) + 1]),
        ("mean", holdout_features[:, len(BASE_CONFIGS) + 2]),
    ]:
        best = best_row_for_scores(holdout_y_array, scores, args.precision_floor)
        baseline_rows.append({"name": name, **best})

    args.scores_output.parent.mkdir(parents=True, exist_ok=True)
    with args.scores_output.open("w") as handle:
        for record_id, row, truth, score, *base_scores in zip(
            holdout_ids,
            holdout_rows,
            holdout_y,
            holdout_meta_scores,
            *final_columns,
        ):
            handle.write(
                json.dumps(
                    {
                        "record_id": record_id,
                        "source": row.get("source"),
                        "label": int(truth),
                        "meta_score": float(score),
                        "base_scores": [float(value) for value in base_scores],
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )

    lines = ["# Score Ensemble Report", ""]
    lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Train label rows: {len(train_label_rows)}")
    lines.append(f"Train OOF rows: {len(oof_y)}")
    lines.append(f"Holdout rows: {len(holdout_y)}")
    lines.append(f"Holdout wake labels: {sum(holdout_y)}")
    lines.append("")
    lines.append("## Base Models")
    lines.append("")
    for index, config in enumerate(BASE_CONFIGS):
        lines.append(f"- base{index}: `{config_name(config)}`")
    lines.append("")
    lines.append("## Selected OOF Metric")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **selected
        )
    )
    lines.append("")
    lines.append("## Holdout")
    lines.append("")
    lines.append("| metric | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| holdout at OOF threshold | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **holdout_at_selected
        )
    )
    lines.append(
        "| holdout best | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **holdout_best
        )
    )
    lines.append("")
    lines.append("## Holdout Score Families")
    lines.append("")
    lines.append("| score | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in baseline_rows:
        lines.append(
            "| {name} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## OOF Groups")
    lines.append("")
    lines.append("| label file | rows | wake |")
    lines.append("| --- | ---: | ---: |")
    for group, rows, wake in group_summaries:
        lines.append(f"| `{group}` | {rows} | {wake} |")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
