#!/usr/bin/env python3
"""Evaluate wake classifiers with each subagent label file held out."""

from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.calibration import CalibratedClassifierCV
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.naive_bayes import ComplementNB
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer
from sklearn.svm import LinearSVC


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "group-holdout-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def text_features(rows: list[dict[str, Any]]) -> list[str]:
    texts: list[str] = []
    for row in rows:
        prefix = [
            f"source={row.get('source') or 'unknown'}",
            f"old_trigger={bool(row.get('old_trigger'))}",
        ]
        matched = row.get("matched_words") or row.get("old_matched_words") or []
        if matched:
            prefix.append("matched=" + ",".join(sorted(map(str, matched))))
        texts.append(" ".join(prefix) + "\n" + compact_text(row.get("text", "")))
    return texts


def label_rows(audit_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            if row.get("record_id"):
                merged = dict(row)
                merged["label_file"] = path.name
                rows.append(merged)
    return rows


def resolved_training_labels(rows: list[dict[str, Any]]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for row in rows:
        votes.setdefault(str(row["record_id"]), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def vectorizer() -> FeatureUnion:
    return FeatureUnion(
        [
            (
                "word",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 4),
                    min_df=1,
                    max_features=90000,
                    strip_accents="unicode",
                    lowercase=True,
                    sublinear_tf=True,
                ),
            ),
            (
                "char",
                TfidfVectorizer(
                    analyzer="char_wb",
                    ngram_range=(3, 6),
                    min_df=1,
                    max_features=90000,
                    lowercase=True,
                    sublinear_tf=True,
                ),
            ),
        ]
    )


def make_model(kind: str) -> Pipeline:
    if kind == "logreg":
        clf = LogisticRegression(
            max_iter=5000,
            class_weight="balanced",
            solver="liblinear",
            C=1.0,
            random_state=42,
        )
    elif kind == "svc":
        clf = CalibratedClassifierCV(
            LinearSVC(class_weight="balanced", C=0.5, random_state=42),
            cv=3,
            method="sigmoid",
        )
    elif kind == "nb":
        clf = ComplementNB(alpha=0.4)
    else:
        raise ValueError(kind)
    return Pipeline(
        [
            ("text", FunctionTransformer(text_features, validate=False)),
            ("features", vectorizer()),
            ("clf", clf),
        ]
    )


def scores_for(model: Pipeline, rows: list[dict[str, Any]]) -> np.ndarray:
    return model.predict_proba(rows)[:, 1]


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


def threshold_rows(y_true: np.ndarray, scores: np.ndarray) -> list[dict[str, float | int]]:
    return [
        metric_row(y_true, scores, threshold)
        for threshold in [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90]
    ]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--kind", choices=["logreg", "svc", "nb"], default="svc")
    args = parser.parse_args()

    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = label_rows(args.audit_dir)
    groups = sorted({str(row["label_file"]) for row in labels})

    all_scores: list[float] = []
    all_truth: list[int] = []
    per_group: list[tuple[str, int, int, dict[str, float | int]]] = []

    for group in groups:
        test_labels = [row for row in labels if row["label_file"] == group]
        test_ids = {str(row["record_id"]) for row in test_labels}
        train_labels = [row for row in labels if str(row["record_id"]) not in test_ids]
        train_resolved = resolved_training_labels(train_labels)

        train_rows: list[dict[str, Any]] = []
        train_y: list[int] = []
        for record_id, should_wake in train_resolved.items():
            record = corpus.get(record_id)
            if record:
                train_rows.append(record)
                train_y.append(int(should_wake))
        if len(set(train_y)) < 2:
            continue

        test_rows: list[dict[str, Any]] = []
        test_y: list[int] = []
        for row in test_labels:
            record = corpus.get(str(row["record_id"]))
            if record:
                test_rows.append(record)
                test_y.append(int(bool(row.get("should_wake"))))
        if not test_rows:
            continue

        model = make_model(args.kind)
        model.fit(train_rows, np.array(train_y, dtype=np.int64))
        scores = scores_for(model, test_rows)
        all_scores.extend(map(float, scores))
        all_truth.extend(test_y)
        y_test = np.array(test_y, dtype=np.int64)
        per_group.append((group, len(test_rows), int(y_test.sum()), metric_row(y_test, scores, 0.50)))

    y_all = np.array(all_truth, dtype=np.int64)
    scores_all = np.array(all_scores, dtype=np.float64)

    lines = ["# Group Holdout Report", ""]
    lines.append(f"Model: {args.kind}")
    lines.append(f"Groups: {len(per_group)}")
    lines.append(f"Evaluated labels: {len(all_truth)}")
    lines.append(f"Positive wake labels: {int(y_all.sum())}")
    lines.extend(["", "## Overall Thresholds", ""])
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_rows(y_all, scores_all):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.extend(["", "## Held-Out Pack At Threshold 0.50", ""])
    lines.append("| pack | rows | positives | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for group, rows_count, positive_count, row in per_group:
        lines.append(
            "| {group} | {rows_count} | {positive_count} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                group=group,
                rows_count=rows_count,
                positive_count=positive_count,
                **row,
            )
        )

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
