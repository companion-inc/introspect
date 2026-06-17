#!/usr/bin/env python3
"""Train and evaluate tiny local intent classifiers from Introspect labels."""

from __future__ import annotations

import argparse
import json
import pickle
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.compose import ColumnTransformer
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix, precision_recall_curve
from sklearn.model_selection import train_test_split
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_LABELS = REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "tfidf-logreg-wake.pkl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "trained-baseline-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def text_features(rows: list[dict[str, Any]]) -> list[str]:
    return [str(row.get("text") or "") for row in rows]


def build_dataset(corpus_path: Path, labels_path: Path, min_confidence: float) -> tuple[list[dict[str, Any]], np.ndarray]:
    corpus = {row["id"]: row for row in read_jsonl(corpus_path)}
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for label in read_jsonl(labels_path):
        if label.get("error"):
            continue
        confidence = float(label.get("confidence") or 0)
        if confidence < min_confidence:
            continue
        record = corpus.get(label.get("record_id"))
        if not record:
            continue
        record = dict(record)
        record.update(
            {
                "qwen_should_wake": bool(label.get("should_wake")),
                "qwen_wake_label": label.get("wake_label"),
                "qwen_route_label": label.get("route_label"),
                "qwen_confidence": confidence,
            }
        )
        rows.append(record)
        y.append(int(bool(label.get("should_wake"))))
    return rows, np.array(y, dtype=np.int64)


def make_model() -> Pipeline:
    word = TfidfVectorizer(
        analyzer="word",
        ngram_range=(1, 3),
        min_df=2,
        max_features=40000,
        strip_accents="unicode",
        lowercase=True,
    )
    char = TfidfVectorizer(
        analyzer="char_wb",
        ngram_range=(3, 5),
        min_df=2,
        max_features=40000,
        lowercase=True,
    )
    features = FeatureUnion([("word", word), ("char", char)])
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


def threshold_table(y_true: np.ndarray, scores: np.ndarray) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    for threshold in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]:
        pred = scores >= threshold
        tp = int(((pred == 1) & (y_true == 1)).sum())
        fp = int(((pred == 1) & (y_true == 0)).sum())
        fn = int(((pred == 0) & (y_true == 1)).sum())
        tn = int(((pred == 0) & (y_true == 0)).sum())
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        wake_rate = (tp + fp) / len(y_true) if len(y_true) else 0.0
        rows.append(
            {
                "threshold": threshold,
                "precision": precision,
                "recall": recall,
                "wake_rate": wake_rate,
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
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--min-confidence", type=float, default=0.65)
    args = parser.parse_args()

    rows, y = build_dataset(args.corpus, args.labels, args.min_confidence)
    if len(set(y.tolist())) < 2:
        raise SystemExit(f"Need both classes after filtering; rows={len(rows)} positives={int(y.sum())}")

    train_rows, test_rows, y_train, y_test = train_test_split(
        rows,
        y,
        test_size=0.25,
        random_state=42,
        stratify=y,
    )
    model = make_model()
    model.fit(train_rows, y_train)
    scores = model.predict_proba(test_rows)[:, 1]
    predictions = (scores >= 0.5).astype(np.int64)

    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump(model, handle)

    lines = ["# Trained Intent Baseline Report", ""]
    lines.append(f"Rows used: {len(rows)}")
    lines.append(f"Train rows: {len(train_rows)}")
    lines.append(f"Test rows: {len(test_rows)}")
    lines.append(f"Positive wake labels: {int(y.sum())}")
    lines.append(f"Model: TF-IDF word+char ngram LogisticRegression")
    lines.append("")
    lines.append("## Thresholds")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_table(y_test, scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Classification Report At 0.50")
    lines.append("")
    lines.append("```text")
    lines.append(classification_report(y_test, predictions, target_names=["no_wake", "wake"], digits=3))
    lines.append("```")
    lines.append("")
    lines.append("## Confusion Matrix At 0.50")
    lines.append("")
    lines.append("Rows=true, columns=predicted.")
    lines.append("")
    lines.append("```text")
    lines.append(str(confusion_matrix(y_test, predictions)))
    lines.append("```")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
