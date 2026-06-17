#!/usr/bin/env python3
"""Train TF-IDF wake classifier and evaluate on subagent audit labels."""

from __future__ import annotations

import argparse
import json
import pickle
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
]
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "tfidf-logreg-wake-audit-eval.pkl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "tfidf-audit-eval-report.md"


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


def audit_by_id(path: Path) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            if row.get("record_id"):
                merged = dict(row)
                merged["audit_file"] = label_file.name
                rows[str(row["record_id"])] = merged
    return rows


def make_model() -> Pipeline:
    features = FeatureUnion(
        [
            (
                "word",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 3),
                    min_df=2,
                    max_features=40000,
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
                    max_features=40000,
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
    for threshold in [0.20, 0.30, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.80, 0.90]:
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
    labels = labels_by_id(args.labels, args.min_confidence)
    audit = audit_by_id(args.audit_dir)

    audit_ids = set(audit)
    train_rows: list[dict[str, Any]] = []
    y_train: list[int] = []
    for record_id, label in labels.items():
        if record_id in audit_ids:
            continue
        record = corpus.get(record_id)
        if not record:
            continue
        train_rows.append(record)
        y_train.append(int(bool(label.get("should_wake"))))

    audit_rows: list[dict[str, Any]] = []
    y_audit: list[int] = []
    for record_id, row in audit.items():
        record = corpus.get(record_id)
        if not record:
            continue
        audit_rows.append(record)
        y_audit.append(int(bool(row.get("should_wake"))))

    if len(set(y_train)) < 2:
        raise SystemExit(f"Need both train classes; rows={len(train_rows)} positives={sum(y_train)}")
    if len(set(y_audit)) < 2:
        raise SystemExit(f"Need both audit classes; rows={len(audit_rows)} positives={sum(y_audit)}")

    model = make_model()
    y_train_array = np.array(y_train, dtype=np.int64)
    model.fit(train_rows, y_train_array)

    y_audit_array = np.array(y_audit, dtype=np.int64)
    scores = model.predict_proba(audit_rows)[:, 1]

    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump(model, handle)

    lines = ["# TF-IDF Audit Evaluation Report", ""]
    lines.append(f"Train labels used: {len(train_rows)}")
    lines.append(f"Train positives: {int(y_train_array.sum())}")
    lines.append(f"Audit labels used: {len(audit_rows)}")
    lines.append(f"Audit positives: {int(y_audit_array.sum())}")
    lines.append(f"Min Qwen confidence: {args.min_confidence:.2f}")
    lines.append("")
    lines.append("## Thresholds On Subagent Audit Labels")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_rows(y_audit_array, scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Classification Report At 0.50")
    lines.append("")
    lines.append("```text")
    lines.append(
        classification_report(
            y_audit_array,
            (scores >= 0.50).astype(np.int64),
            target_names=["no_wake", "wake"],
            digits=3,
        )
    )
    lines.append("```")
    lines.append("")
    lines.append("## Confusion Matrix At 0.50")
    lines.append("")
    lines.append("Rows=true, columns=predicted.")
    lines.append("")
    lines.append("```text")
    lines.append(str(confusion_matrix(y_audit_array, (scores >= 0.50).astype(np.int64))))
    lines.append("```")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
