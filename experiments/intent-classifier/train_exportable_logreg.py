#!/usr/bin/env python3
"""Train an exportable TF-IDF logistic wake classifier."""

from __future__ import annotations

import argparse
import json
import math
import pickle
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.model_selection import StratifiedKFold
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "wake-logreg-exportable.pkl"
DEFAULT_JSON = REPO / "feedback" / "intent-classifier" / "wake-logreg-exportable.json"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "wake-logreg-exportable-report.md"


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


def audit_votes(path: Path) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            record_id = row.get("record_id")
            if record_id:
                votes.setdefault(str(record_id), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, rows in votes.items():
        counts = Counter(rows)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def dataset(corpus_path: Path, audit_dir: Path) -> tuple[list[dict[str, Any]], np.ndarray]:
    corpus = {str(row["id"]): row for row in read_jsonl(corpus_path)}
    audit = audit_votes(audit_dir)
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, should_wake in audit.items():
        record = corpus.get(record_id)
        if record:
            rows.append(record)
            y.append(int(should_wake))
    return rows, np.array(y, dtype=np.int64)


def make_model(max_word_features: int, max_char_features: int) -> Pipeline:
    features = FeatureUnion(
        [
            (
                "word",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 4),
                    min_df=1,
                    max_features=max_word_features,
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
                    max_features=max_char_features,
                    lowercase=True,
                    sublinear_tf=True,
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
                    max_iter=5000,
                    class_weight="balanced",
                    solver="liblinear",
                    C=1.0,
                    random_state=42,
                ),
            ),
        ]
    )


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


def export_vectorizer(vectorizer: TfidfVectorizer, coefs: np.ndarray) -> dict[str, Any]:
    by_index = {index: term for term, index in vectorizer.vocabulary_.items()}
    features: list[list[Any]] = []
    for index in sorted(by_index):
        coef = float(coefs[index])
        if coef == 0:
            continue
        features.append([by_index[index], float(vectorizer.idf_[index]), coef])
    return {
        "ngram_range": list(vectorizer.ngram_range),
        "sublinear_tf": bool(vectorizer.sublinear_tf),
        "lowercase": bool(vectorizer.lowercase),
        "strip_accents": vectorizer.strip_accents,
        "features": features,
    }


def export_model(model: Pipeline, path: Path, threshold: float, report: dict[str, Any]) -> None:
    union: FeatureUnion = model.named_steps["features"]
    clf: LogisticRegression = model.named_steps["clf"]
    word = union.transformer_list[0][1]
    char = union.transformer_list[1][1]
    word_count = len(word.vocabulary_)
    coef = clf.coef_[0]
    obj = {
        "version": 1,
        "model_type": "tfidf_logreg_wake",
        "threshold": threshold,
        "text_prefix_fields": ["source", "old_trigger", "matched_words"],
        "word": export_vectorizer(word, coef[:word_count]),
        "char_wb": export_vectorizer(char, coef[word_count:]),
        "intercept": float(clf.intercept_[0]),
        "report": report,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--json-output", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--threshold", type=float, default=0.50)
    parser.add_argument("--max-word-features", type=int, default=30000)
    parser.add_argument("--max-char-features", type=int, default=30000)
    args = parser.parse_args()

    rows, y = dataset(args.corpus, args.audit_dir)
    split = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    scores = np.zeros(len(rows), dtype=np.float64)
    for train_index, test_index in split.split(np.zeros(len(rows)), y):
        fold_model = make_model(args.max_word_features, args.max_char_features)
        train_rows = [rows[index] for index in train_index]
        test_rows = [rows[index] for index in test_index]
        fold_model.fit(train_rows, y[train_index])
        scores[test_index] = fold_model.predict_proba(test_rows)[:, 1]

    model = make_model(args.max_word_features, args.max_char_features)
    model.fit(rows, y)
    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump(model, handle)

    selected = metric_row(y, scores, args.threshold)
    report_obj = {
        "rows": len(rows),
        "positives": int(y.sum()),
        "threshold": args.threshold,
        "precision": selected["precision"],
        "recall": selected["recall"],
        "wake_rate": selected["wake_rate"],
        "max_word_features": args.max_word_features,
        "max_char_features": args.max_char_features,
    }
    export_model(model, args.json_output, args.threshold, report_obj)

    lines = ["# Exportable Wake LogReg Report", ""]
    lines.append(f"Rows: {len(rows)}")
    lines.append(f"Positive wake labels: {int(y.sum())}")
    lines.append(f"Word features: {len(model.named_steps['features'].transformer_list[0][1].vocabulary_)}")
    lines.append(f"Char features: {len(model.named_steps['features'].transformer_list[1][1].vocabulary_)}")
    lines.append(f"Export JSON: {args.json_output}")
    lines.append("")
    lines.append("## 5-Fold CV Thresholds")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_rows(y, scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
