#!/usr/bin/env python3
"""Train and select an exportable v2 Introspect wake-intent classifier."""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "intent-v2-grid-report.md"
DEFAULT_JSON = REPO / "feedback" / "intent-classifier" / "wake-logreg-v2.json"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def text_features(rows: list[dict[str, Any]], prefix_fields: list[str]) -> list[str]:
    texts: list[str] = []
    for row in rows:
        prefix: list[str] = []
        if "source" in prefix_fields:
            prefix.append(f"source={row.get('source') or 'unknown'}")
        if "old_trigger" in prefix_fields:
            prefix.append(f"old_trigger={bool(row.get('old_trigger'))}")
        matched = row.get("matched_words") or row.get("old_matched_words") or []
        if "matched_words" in prefix_fields and matched:
            prefix.append("matched=" + ",".join(sorted(map(str, matched))))
        body = compact_text(row.get("text", ""))
        texts.append((" ".join(prefix) + "\n" + body) if prefix else body)
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


def resolved_labels(rows: list[dict[str, Any]]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for row in rows:
        votes.setdefault(str(row["record_id"]), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def load_corpora(paths: list[Path]) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for path in paths:
        for row in read_jsonl(path):
            row_id = row.get("id")
            if row_id:
                rows[str(row_id)] = row
    return rows


def aux_examples(
    corpora: dict[str, dict[str, Any]],
    label_paths: list[Path],
    exclude_ids: set[str],
    min_confidence: float,
    include_positive: bool,
    include_negative: bool,
) -> tuple[list[dict[str, Any]], list[int]]:
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    seen: set[str] = set()
    for path in label_paths:
        for label in read_jsonl(path):
            record_id = str(label.get("record_id") or "")
            if not record_id or record_id in exclude_ids or record_id in seen or label.get("error"):
                continue
            if not isinstance(label.get("should_wake"), bool):
                continue
            confidence = float(label.get("confidence") or 0.0)
            if confidence < min_confidence:
                continue
            should_wake = bool(label.get("should_wake"))
            if should_wake and not include_positive:
                continue
            if not should_wake and not include_negative:
                continue
            record = corpora.get(record_id)
            if not record:
                continue
            merged = dict(record)
            merged["aux_label_source"] = path.name
            merged["aux_confidence"] = confidence
            rows.append(merged)
            y.append(int(should_wake))
            seen.add(record_id)
    return rows, y


def make_model(
    *,
    prefix_fields: list[str],
    max_word_features: int,
    max_char_features: int,
    c_value: float,
    class_weight: str | None,
) -> Pipeline:
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
            ("text", FunctionTransformer(text_features, validate=False, kw_args={"prefix_fields": prefix_fields})),
            ("features", features),
            (
                "clf",
                LogisticRegression(
                    max_iter=5000,
                    class_weight=class_weight,
                    solver="liblinear",
                    C=c_value,
                    random_state=42,
                ),
            ),
        ]
    )


def fit_model(model: Pipeline, rows: list[dict[str, Any]], y: list[int], weights: list[float] | None) -> None:
    y_array = np.array(y, dtype=np.int64)
    if weights:
        model.fit(rows, y_array, clf__sample_weight=np.array(weights, dtype=np.float64))
    else:
        model.fit(rows, y_array)


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


def threshold_grid() -> list[float]:
    return [round(value / 1000, 3) for value in range(200, 951, 5)]


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if not viable:
        return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"])))
    return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))


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


def export_model(model: Pipeline, path: Path, threshold: float, prefix_fields: list[str], report: dict[str, Any]) -> None:
    union: FeatureUnion = model.named_steps["features"]
    clf: LogisticRegression = model.named_steps["clf"]
    word = union.transformer_list[0][1]
    char = union.transformer_list[1][1]
    word_count = len(word.vocabulary_)
    coef = clf.coef_[0]
    obj = {
        "version": 2,
        "model_type": "tfidf_logreg_wake_v2",
        "threshold": threshold,
        "text_prefix_fields": prefix_fields,
        "word": export_vectorizer(word, coef[:word_count]),
        "char_wb": export_vectorizer(char, coef[word_count:]),
        "intercept": float(clf.intercept_[0]),
        "report": report,
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")


def config_name(config: dict[str, Any]) -> str:
    fields = ",".join(config["prefix_fields"]) if config["prefix_fields"] else "none"
    return (
        f"prefix={fields};word={config['max_word_features']};char={config['max_char_features']};"
        f"C={config['c_value']};class_weight={config['class_weight'] or 'none'}"
    )


def result_sort_key(result: dict[str, Any], precision_floor: float) -> tuple[float, float, float, float]:
    if float(result["precision"]) >= precision_floor:
        return (1.0, float(result["recall"]), float(result["precision"]), -float(result["wake_rate"]))
    return (0.0, float(result["precision"]), float(result["recall"]), -float(result["wake_rate"]))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--aux-corpus", type=Path, action="append", default=[])
    parser.add_argument("--aux-labels", type=Path, action="append", default=[])
    parser.add_argument("--aux-weight", type=float, default=0.20)
    parser.add_argument("--min-aux-confidence", type=float, default=0.80)
    parser.add_argument("--no-aux-positives", action="store_true")
    parser.add_argument("--no-aux-negatives", action="store_true")
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--prefix-fields", default="source")
    parser.add_argument("--feature-sizes", default="30000,60000,90000")
    parser.add_argument("--c-values", default="0.25,0.5,1.0,2.0,4.0")
    parser.add_argument("--class-weights", default="balanced,none")
    parser.add_argument("--holdout-pattern", action="append", default=[])
    parser.add_argument("--export-all-labels", action="store_true")
    parser.add_argument("--json-output", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    corpus = load_corpora([args.corpus])
    all_corpora = load_corpora([args.corpus] + args.aux_corpus)
    labels = label_rows(args.audit_dir)
    groups = sorted({str(row["label_file"]) for row in labels})
    gold_ids = {str(row["record_id"]) for row in labels}

    aux_rows_all, aux_y_all = aux_examples(
        all_corpora,
        args.aux_labels,
        exclude_ids=gold_ids,
        min_confidence=args.min_aux_confidence,
        include_positive=not args.no_aux_positives,
        include_negative=not args.no_aux_negatives,
    )
    aux_weight_all = [args.aux_weight] * len(aux_rows_all)

    prefix_fields = [field for field in args.prefix_fields.split(",") if field]
    feature_sizes = [int(value) for value in args.feature_sizes.split(",") if value]
    c_values = [float(value) for value in args.c_values.split(",") if value]
    class_weights = [None if value == "none" else value for value in args.class_weights.split(",") if value]

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

    evaluated: list[dict[str, Any]] = []
    best: dict[str, Any] | None = None
    holdout_labels: list[dict[str, Any]] = []
    holdout_ids: set[str] = set()
    if args.holdout_pattern:
        holdout_labels = [
            row
            for row in labels
            if any(fnmatch.fnmatch(str(row["label_file"]), pattern) for pattern in args.holdout_pattern)
        ]
        holdout_ids = {str(row["record_id"]) for row in holdout_labels}
        groups = [",".join(args.holdout_pattern)]

    for config in configs:
        all_scores: list[float] = []
        all_truth: list[int] = []
        eval_groups = groups if not args.holdout_pattern else [",".join(args.holdout_pattern)]
        for group in eval_groups:
            if args.holdout_pattern:
                test_labels = holdout_labels
                test_ids = holdout_ids
                train_labels = [
                    row
                    for row in labels
                    if str(row["record_id"]) not in holdout_ids
                    and not any(fnmatch.fnmatch(str(row["label_file"]), pattern) for pattern in args.holdout_pattern)
                ]
            else:
                test_labels = [row for row in labels if row["label_file"] == group]
                test_ids = {str(row["record_id"]) for row in test_labels}
                train_labels = [row for row in labels if str(row["record_id"]) not in test_ids]

            train_resolved = resolved_labels(train_labels)

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

            aux_rows = [row for row in aux_rows_all if str(row.get("id")) not in test_ids]
            aux_y = [label for row, label in zip(aux_rows_all, aux_y_all) if str(row.get("id")) not in test_ids]
            weights = [1.0] * len(train_rows) + aux_weight_all[: len(aux_rows)]
            model = make_model(**config)
            fit_model(model, train_rows + aux_rows, train_y + aux_y, weights if aux_rows else None)
            scores = scores_for(model, test_rows)
            all_scores.extend(map(float, scores))
            all_truth.extend(test_y)

        if not all_truth:
            continue
        y_all = np.array(all_truth, dtype=np.int64)
        scores_all = np.array(all_scores, dtype=np.float64)
        selected = best_at_precision(y_all, scores_all, args.precision_floor)
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
            "evaluated_labels": len(all_truth),
            "positive_labels": int(y_all.sum()),
        }
        evaluated.append(result)
        if best is None or result_sort_key(result, args.precision_floor) > result_sort_key(best, args.precision_floor):
            best = result
        print(json.dumps({"candidate": result["name"], "precision": result["precision"], "recall": result["recall"], "threshold": result["threshold"]}, sort_keys=True), flush=True)

    if best is None:
        raise SystemExit("No candidate evaluated")

    final_config = best["config"]
    if args.holdout_pattern and not args.export_all_labels:
        export_label_rows = [
            row
            for row in labels
            if str(row["record_id"]) not in holdout_ids
            and not any(fnmatch.fnmatch(str(row["label_file"]), pattern) for pattern in args.holdout_pattern)
        ]
        export_includes_holdout = False
    else:
        export_label_rows = labels
        export_includes_holdout = True
    final_labels = resolved_labels(export_label_rows)
    final_rows: list[dict[str, Any]] = []
    final_y: list[int] = []
    for record_id, should_wake in final_labels.items():
        record = corpus.get(record_id)
        if record:
            final_rows.append(record)
            final_y.append(int(should_wake))
    final_rows.extend(aux_rows_all)
    final_y.extend(aux_y_all)
    final_weights = [1.0] * (len(final_rows) - len(aux_rows_all)) + aux_weight_all
    final_model = make_model(**final_config)
    fit_model(final_model, final_rows, final_y, final_weights if aux_rows_all else None)

    report_obj = {
        "selected_threshold": best["threshold"],
        "precision_floor": args.precision_floor,
        "precision": best["precision"],
        "recall": best["recall"],
        "wake_rate": best["wake_rate"],
        "tp": best["tp"],
        "fp": best["fp"],
        "fn": best["fn"],
        "tn": best["tn"],
        "gold_train_rows": len(final_rows) - len(aux_rows_all),
        "export_includes_holdout": export_includes_holdout,
        "export_holdout_patterns": args.holdout_pattern,
        "aux_train_rows": len(aux_rows_all),
        "aux_weight": args.aux_weight,
        "min_aux_confidence": args.min_aux_confidence,
        "config": final_config,
    }
    export_model(final_model, args.json_output, float(best["threshold"]), final_config["prefix_fields"], report_obj)

    ranked = sorted(
        evaluated,
        key=lambda row: result_sort_key(row, args.precision_floor),
        reverse=True,
    )
    lines = ["# Intent Classifier V2 Grid Report", ""]
    if args.holdout_pattern:
        lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Gold label rows: {len(labels)}")
    lines.append(f"Gold unique ids: {len(gold_ids)}")
    lines.append(f"Auxiliary train rows: {len(aux_rows_all)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Selected: `{best['name']}`")
    lines.append(f"Selected threshold: {float(best['threshold']):.3f}")
    lines.append(f"Export JSON: {args.json_output}")
    lines.append("")
    lines.append("## Selected Group-Holdout Metrics")
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
