#!/usr/bin/env python3
"""Train and cross-validate wake classifiers on audited subagent labels only."""

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
from sklearn.metrics import confusion_matrix
from sklearn.model_selection import StratifiedKFold
from sklearn.naive_bayes import ComplementNB
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer
from sklearn.svm import LinearSVC
from sklearn.calibration import CalibratedClassifierCV


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "audit-only-cv-report.md"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "audit-only-wake.pkl"


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
        resolved[record_id] = {
            "record_id": record_id,
            "should_wake": counts[True] >= counts[False],
            "votes": len(rows),
            "true_votes": counts[True],
            "false_votes": counts[False],
        }
    return resolved


def dataset(corpus_path: Path, audit_dir: Path) -> tuple[list[dict[str, Any]], np.ndarray]:
    corpus = {str(row["id"]): row for row in read_jsonl(corpus_path)}
    audit = audit_votes(audit_dir)
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, label in audit.items():
        record = corpus.get(record_id)
        if not record:
            continue
        rows.append(record)
        y.append(int(bool(label["should_wake"])))
    return rows, np.array(y, dtype=np.int64)


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
    if hasattr(model[-1], "predict_proba"):
        return model.predict_proba(rows)[:, 1]
    decision = model.decision_function(rows)
    return 1 / (1 + np.exp(-decision))


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
        for threshold in [0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80, 0.85, 0.90]
    ]


def best_with(rows: list[dict[str, float | int]], *, min_precision: float = 0.0, min_recall: float = 0.0) -> dict[str, float | int] | None:
    candidates = [
        row for row in rows
        if float(row["precision"]) >= min_precision and float(row["recall"]) >= min_recall
    ]
    if not candidates:
        return None
    return max(candidates, key=lambda row: (float(row["recall"]), float(row["precision"])))


def row_summary(row: dict[str, float | int] | None) -> str:
    if not row:
        return "none"
    return (
        "threshold={threshold:.2f} precision={precision:.2f} recall={recall:.2f} "
        "wake_rate={wake_rate:.2f} TP={tp} FP={fp} FN={fn} TN={tn}"
    ).format(**row)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    args = parser.parse_args()

    rows, y = dataset(args.corpus, args.audit_dir)
    if len(set(y.tolist())) < 2:
        raise SystemExit(f"Need both classes; rows={len(rows)} positives={int(y.sum())}")

    split = StratifiedKFold(n_splits=5, shuffle=True, random_state=42)
    model_kinds = ["logreg", "svc", "nb"]
    results: dict[str, np.ndarray] = {}
    for kind in model_kinds:
        out = np.zeros(len(rows), dtype=np.float64)
        for train_index, test_index in split.split(np.zeros(len(rows)), y):
            model = make_model(kind)
            train_rows = [rows[index] for index in train_index]
            test_rows = [rows[index] for index in test_index]
            model.fit(train_rows, y[train_index])
            out[test_index] = scores_for(model, test_rows)
        results[kind] = out

    results["mean_logreg_svc"] = (results["logreg"] + results["svc"]) / 2
    results["mean_all"] = (results["logreg"] + results["svc"] + results["nb"]) / 3

    best_kind = max(
        results,
        key=lambda kind: max(
            (row["precision"], row["recall"])
            for row in threshold_rows(y, results[kind])
            if row["recall"] >= 0.65
        ) if any(row["recall"] >= 0.65 for row in threshold_rows(y, results[kind])) else (0, 0),
    )
    final_model = make_model(best_kind if best_kind in model_kinds else "logreg")
    final_model.fit(rows, y)
    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump({"kind": best_kind, "model": final_model}, handle)

    lines = ["# Audit-Only CV Report", ""]
    lines.append(f"Rows: {len(rows)}")
    lines.append(f"Positive wake labels: {int(y.sum())}")
    lines.append(f"Best model by precision with recall >= 0.65: {best_kind}")
    for kind, scores in results.items():
        rows_for_kind = threshold_rows(y, scores)
        lines.extend(["", f"## {kind}", ""])
        lines.append(f"Best auto-wake point (precision >= 0.80): {row_summary(best_with(rows_for_kind, min_precision=0.80))}")
        lines.append(f"Best balanced point (precision >= 0.70, recall >= 0.50): {row_summary(best_with(rows_for_kind, min_precision=0.70, min_recall=0.50))}")
        lines.append(f"Best review point (recall >= 0.80): {row_summary(best_with(rows_for_kind, min_recall=0.80))}")
        lines.append("")
        lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
        lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for row in rows_for_kind:
            lines.append(
                "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                    **row
                )
            )
        best_050 = metric_row(y, scores, 0.50)
        lines.extend(["", "Confusion matrix at 0.50:", "", "```text"])
        lines.append(str(confusion_matrix(y, scores >= 0.50)))
        lines.append("```")
        lines.append(
            "At 0.50: precision={precision:.3f} recall={recall:.3f} wake_rate={wake_rate:.3f}".format(
                **best_050
            )
        )

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
