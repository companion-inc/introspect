#!/usr/bin/env python3
"""Train TF-IDF wake classifier with subagent audit labels as overrides."""

from __future__ import annotations

import argparse
import json
import pickle
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import train_test_split
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
]
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "tfidf-logreg-wake-audit-overrides.pkl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "tfidf-audit-overrides-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def text_features(rows: list[dict[str, Any]]) -> list[str]:
    return [str(row.get("text") or "") for row in rows]


def labels_by_id(paths: list[Path], min_confidence: float) -> dict[str, dict[str, Any]]:
    labels: dict[str, dict[str, Any]] = {}
    for path in paths:
        for row in read_jsonl(path):
            if row.get("error") or not row.get("record_id"):
                continue
            if float(row.get("confidence") or 0) < min_confidence:
                continue
            labels[str(row["record_id"])] = row
    return labels


def audit_votes(path: Path) -> dict[str, dict[str, Any]]:
    votes: dict[str, list[dict[str, Any]]] = {}
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            record_id = row.get("record_id")
            if record_id:
                votes.setdefault(str(record_id), []).append(row)
    resolved: dict[str, dict[str, Any]] = {}
    for record_id, rows in votes.items():
        counts = Counter(bool(row.get("should_wake")) for row in rows)
        should_wake = counts[True] >= counts[False]
        resolved[record_id] = {
            "record_id": record_id,
            "should_wake": should_wake,
            "votes": len(rows),
            "true_votes": counts[True],
            "false_votes": counts[False],
        }
    return resolved


def make_model() -> Pipeline:
    features = FeatureUnion(
        [
            (
                "word",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 3),
                    min_df=2,
                    max_features=50000,
                    strip_accents="unicode",
                    lowercase=True,
                ),
            ),
            (
                "char",
                TfidfVectorizer(
                    analyzer="char_wb",
                    ngram_range=(3, 5),
                    min_df=2,
                    max_features=50000,
                    lowercase=True,
                ),
            ),
        ]
    )
    return Pipeline(
        [
            ("text", FunctionTransformer(text_features, validate=False)),
            ("features", features),
            (
                "clf",
                LogisticRegression(
                    max_iter=3000,
                    class_weight="balanced",
                    solver="liblinear",
                    random_state=42,
                ),
            ),
        ]
    )


def threshold_rows(y_true: np.ndarray, scores: np.ndarray) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    for threshold in [0.20, 0.30, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.90]:
        pred = scores >= threshold
        tp = int(((pred == 1) & (y_true == 1)).sum())
        fp = int(((pred == 1) & (y_true == 0)).sum())
        fn = int(((pred == 0) & (y_true == 1)).sum())
        tn = int(((pred == 0) & (y_true == 0)).sum())
        rows.append(
            {
                "threshold": threshold,
                "precision": tp / (tp + fp) if tp + fp else 0.0,
                "recall": tp / (tp + fn) if tp + fn else 0.0,
                "wake_rate": (tp + fp) / len(y_true) if len(y_true) else 0.0,
                "tp": tp,
                "fp": fp,
                "fn": fn,
                "tn": tn,
            }
        )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--labels", type=Path, nargs="*", default=DEFAULT_LABELS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--min-confidence", type=float, default=0.65)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    qwen = labels_by_id(args.labels, args.min_confidence)
    audit = audit_votes(args.audit_dir)

    train_pool: list[dict[str, Any]] = []
    train_y: list[int] = []
    audit_rows: list[dict[str, Any]] = []
    audit_y: list[int] = []

    audit_ids = set(audit)
    for record_id, label in qwen.items():
        if record_id in audit_ids:
            continue
        record = corpus.get(record_id)
        if not record:
            continue
        train_pool.append(record)
        train_y.append(int(bool(label.get("should_wake"))))

    for record_id, label in audit.items():
        record = corpus.get(record_id)
        if not record:
            continue
        audit_rows.append(record)
        audit_y.append(int(bool(label.get("should_wake"))))

    if len(set(train_y)) < 2:
        raise SystemExit(f"Need both train classes; rows={len(train_pool)} positives={sum(train_y)}")
    if len(set(audit_y)) < 2:
        raise SystemExit(f"Need both audit classes; rows={len(audit_rows)} positives={sum(audit_y)}")

    train_rows, dev_rows, y_train, y_dev = train_test_split(
        train_pool,
        np.array(train_y, dtype=np.int64),
        test_size=0.20,
        random_state=42,
        stratify=np.array(train_y, dtype=np.int64),
    )

    model = make_model()
    model.fit(train_rows, y_train)

    y_audit = np.array(audit_y, dtype=np.int64)
    audit_scores = model.predict_proba(audit_rows)[:, 1]
    dev_scores = model.predict_proba(dev_rows)[:, 1]

    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump(model, handle)

    lines = ["# TF-IDF Audit Override Report", ""]
    lines.append(f"Qwen train pool rows after audit holdout: {len(train_pool)}")
    lines.append(f"Qwen train pool positives: {sum(train_y)}")
    lines.append(f"Train rows: {len(train_rows)}")
    lines.append(f"Dev rows: {len(dev_rows)}")
    lines.append(f"Audit unique rows: {len(audit_rows)}")
    lines.append(f"Audit positives: {int(y_audit.sum())}")
    lines.append(f"Min Qwen confidence: {args.min_confidence:.2f}")
    lines.append("")
    lines.append("## Thresholds On Subagent Audit Labels")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_rows(y_audit, audit_scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Thresholds On Qwen Dev Labels")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_rows(y_dev, dev_scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Audit Classification Report At 0.50")
    lines.append("")
    lines.append("```text")
    lines.append(
        classification_report(
            y_audit,
            (audit_scores >= 0.50).astype(np.int64),
            target_names=["no_wake", "wake"],
            digits=3,
        )
    )
    lines.append("```")
    lines.append("")
    lines.append("## Audit Confusion Matrix At 0.50")
    lines.append("")
    lines.append("Rows=true, columns=predicted.")
    lines.append("")
    lines.append("```text")
    lines.append(str(confusion_matrix(y_audit, (audit_scores >= 0.50).astype(np.int64))))
    lines.append("```")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
