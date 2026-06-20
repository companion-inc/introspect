#!/usr/bin/env python3
"""Evaluate embedding + logistic wake classifiers with soft teacher labels."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression

from evaluate_embedding_holdout import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    DEFAULT_ENDPOINT,
    DEFAULT_MODEL,
    embeddings_for,
    metric_row,
    read_jsonl,
    resolved_training_labels,
)
from train_distilled_tfidf_student import parse_float


REPO = Path(__file__).resolve().parents[2]
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "embedding-teacher-student-report.md"
DEFAULT_CACHE = REPO / "feedback" / "intent-classifier" / "embedding-cache" / "nomic-teacher-student.npz"


def label_rows(audit_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            if row.get("record_id"):
                merged = dict(row)
                merged["label_file"] = path.name
                rows.append(merged)
    return rows


def teacher_probability(row: dict[str, Any]) -> float | None:
    if row.get("error"):
        return None
    probability = parse_float(row.get("wake_probability"))
    if probability is not None:
        return min(max(probability, 0.01), 0.99)
    if not isinstance(row.get("should_wake"), bool):
        return None
    confidence = parse_float(row.get("confidence"))
    if confidence is None:
        confidence = 0.8
    confidence = min(max(confidence, 0.5), 0.99)
    return confidence if row["should_wake"] else 1.0 - confidence


def threshold_grid() -> list[float]:
    return [round(value / 1000, 3) for value in range(200, 951, 5)]


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if not viable:
        return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"])))
    return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))


def append_soft_teacher(
    *,
    train_indices: list[int],
    train_y: list[int],
    weights: list[float],
    index_by_id: dict[str, int],
    teacher_scores: dict[str, float],
    exclude_ids: set[str],
    teacher_weight: float,
) -> None:
    for record_id, score in teacher_scores.items():
        if record_id in exclude_ids:
            continue
        index = index_by_id.get(record_id)
        if index is None:
            continue
        positive_weight = teacher_weight * score
        negative_weight = teacher_weight * (1.0 - score)
        if positive_weight > 0:
            train_indices.append(index)
            train_y.append(1)
            weights.append(positive_weight)
        if negative_weight > 0:
            train_indices.append(index)
            train_y.append(0)
            weights.append(negative_weight)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--teacher-labels", type=Path, required=True)
    parser.add_argument("--teacher-weights", default="0.05,0.1,0.2,0.5,1.0")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--batch-size", type=int, default=96)
    parser.add_argument("--max-chars", type=int, default=1600)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--c-values", default="0.25,0.5,1.0,2.0,4.0,8.0")
    parser.add_argument("--include-source", action="store_true")
    args = parser.parse_args()

    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = label_rows(args.audit_dir)
    groups = sorted({str(row["label_file"]) for row in labels})
    gold_ids = {str(row["record_id"]) for row in labels if str(row["record_id"]) in corpus}

    teacher_scores: dict[str, float] = {}
    for row in read_jsonl(args.teacher_labels):
        record_id = row.get("record_id")
        if not record_id or str(record_id) in gold_ids:
            continue
        score = teacher_probability(row)
        if score is not None and str(record_id) in corpus:
            teacher_scores[str(record_id)] = score

    ids = sorted(gold_ids | set(teacher_scores))
    rows = [corpus[row_id] for row_id in ids]
    embed_ids, embeddings = embeddings_for(
        rows,
        args.cache,
        args.endpoint,
        args.model,
        args.batch_size,
        args.max_chars,
        args.include_source,
        args.timeout,
    )
    index_by_id = {str(row_id): index for index, row_id in enumerate(embed_ids)}

    c_values = [float(value) for value in args.c_values.split(",") if value]
    teacher_weights = [float(value) for value in args.teacher_weights.split(",") if value]
    results: list[dict[str, Any]] = []

    for teacher_weight in teacher_weights:
        for c_value in c_values:
            all_scores: list[float] = []
            all_truth: list[int] = []
            for group in groups:
                test_labels = [row for row in labels if row["label_file"] == group]
                test_ids = {str(row["record_id"]) for row in test_labels}
                train_labels = [row for row in labels if str(row["record_id"]) not in test_ids]
                train_resolved = resolved_training_labels(train_labels)
                train_indices: list[int] = []
                train_y: list[int] = []
                weights: list[float] = []
                for record_id, should_wake in train_resolved.items():
                    index = index_by_id.get(record_id)
                    if index is not None:
                        train_indices.append(index)
                        train_y.append(int(should_wake))
                        weights.append(1.0)
                append_soft_teacher(
                    train_indices=train_indices,
                    train_y=train_y,
                    weights=weights,
                    index_by_id=index_by_id,
                    teacher_scores=teacher_scores,
                    exclude_ids=test_ids,
                    teacher_weight=teacher_weight,
                )
                test_indices: list[int] = []
                test_y: list[int] = []
                for row in test_labels:
                    index = index_by_id.get(str(row["record_id"]))
                    if index is not None:
                        test_indices.append(index)
                        test_y.append(int(bool(row.get("should_wake"))))
                if len(set(train_y)) < 2 or not test_indices:
                    continue
                clf = LogisticRegression(
                    max_iter=3000,
                    class_weight="balanced",
                    solver="liblinear",
                    C=c_value,
                    random_state=42,
                )
                clf.fit(
                    embeddings[train_indices],
                    np.array(train_y, dtype=np.int64),
                    sample_weight=np.array(weights, dtype=np.float64),
                )
                scores = clf.predict_proba(embeddings[test_indices])[:, 1]
                all_scores.extend(map(float, scores))
                all_truth.extend(test_y)
            y_all = np.array(all_truth, dtype=np.int64)
            scores_all = np.array(all_scores, dtype=np.float64)
            selected = best_at_precision(y_all, scores_all, args.precision_floor)
            result = {"teacher_weight": teacher_weight, "c_value": c_value, **selected}
            results.append(result)
            print(json.dumps(result, sort_keys=True), flush=True)

    ranked = sorted(
        results,
        key=lambda row: (
            float(row["precision"]) >= args.precision_floor,
            float(row["recall"]),
            float(row["precision"]),
            -float(row["wake_rate"]),
        ),
        reverse=True,
    )
    best = ranked[0]

    teacher_label_counts = Counter(round(score, 2) for score in teacher_scores.values())
    lines = ["# Embedding Teacher-Student Report", ""]
    lines.append(f"Embedding model: {args.model}")
    lines.append(f"Gold unique rows: {len(gold_ids)}")
    lines.append(f"Teacher unique rows: {len(teacher_scores)}")
    lines.append(f"Evaluated labels: {len(labels)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Include source prefix: {args.include_source}")
    lines.append(f"Teacher score buckets: {dict(sorted(teacher_label_counts.items()))}")
    lines.append("")
    lines.append("## Best")
    lines.append("")
    lines.append("| teacher weight | C | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {teacher_weight:.2f} | {c_value:.2f} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **best
        )
    )
    lines.append("")
    lines.append("## Top Candidates")
    lines.append("")
    lines.append("| rank | teacher weight | C | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for rank, row in enumerate(ranked[:30], 1):
        lines.append(
            "| {rank} | {teacher_weight:.2f} | {c_value:.2f} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                rank=rank,
                **row,
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
