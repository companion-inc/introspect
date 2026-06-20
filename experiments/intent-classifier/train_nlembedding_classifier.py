#!/usr/bin/env python3
"""Train and evaluate an Apple NaturalLanguage sentence-embedding wake classifier."""

from __future__ import annotations

import argparse
import fnmatch
import json
import subprocess
import tempfile
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    best_at_precision,
    label_rows,
    load_corpora,
    metric_row,
    resolved_labels,
    threshold_grid,
)


REPO = Path(__file__).resolve().parents[2]
EXPORTER = REPO / "experiments" / "intent-classifier" / "export_nlembedding_features.swift"
DEFAULT_FEATURES = REPO / "feedback" / "intent-classifier" / "nlembedding-round7-features.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "nlembedding-round7-report.md"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "nlembedding-round7-scores.jsonl"


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def rows_for_labels(corpus: dict[str, dict[str, Any]], labels: dict[str, bool], split: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for record_id, should_wake in sorted(labels.items()):
        record = corpus.get(record_id)
        if not record:
            continue
        rows.append(
            {
                "id": record_id,
                "source": record.get("source") or "unknown",
                "text": record.get("text") or "",
                "label": int(should_wake),
                "split": split,
            }
        )
    return rows


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def read_feature_rows(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str, max_characters: int) -> str:
    return " ".join(text.split())[:max_characters]


def feature_input_rows(rows: list[dict[str, Any]], max_characters: int) -> list[dict[str, Any]]:
    return [{**row, "text": compact_text(str(row.get("text") or ""), max_characters)} for row in rows]


def ensure_features(rows: list[dict[str, Any]], features_path: Path, refresh: bool, max_characters: int) -> None:
    if features_path.exists() and not refresh:
        return
    with tempfile.TemporaryDirectory(prefix="introspect-nlembedding-") as tmp:
        input_path = Path(tmp) / "rows.jsonl"
        binary_path = Path(tmp) / "export_nlembedding_features"
        write_jsonl(input_path, feature_input_rows(rows, max_characters))
        subprocess.run(
            [
                "swiftc",
                "-O",
                "-framework",
                "NaturalLanguage",
                str(EXPORTER),
                "-o",
                str(binary_path),
            ],
            check=True,
            cwd=REPO,
        )
        subprocess.run(
            [
                str(binary_path),
                "--input",
                str(input_path),
                "--output",
                str(features_path),
                "--max-characters",
                str(max_characters),
            ],
            check=True,
            cwd=REPO,
        )


def model(c_value: float, class_weight: str | None) -> Pipeline:
    return Pipeline(
        [
            ("scale", StandardScaler()),
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


def best_metric(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if viable:
        return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))
    return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"]), -float(row["wake_rate"])))


def matrix(rows: list[dict[str, Any]]) -> tuple[list[str], np.ndarray, np.ndarray, list[dict[str, Any]]]:
    ids = [str(row["id"]) for row in rows]
    x = np.array([row["vector"] for row in rows], dtype=np.float64)
    y = np.array([int(row["label"]) for row in rows], dtype=np.int64)
    return ids, x, y, rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--holdout-pattern", action="append", default=None)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--features", type=Path, default=DEFAULT_FEATURES)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--scores-output", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--refresh-features", action="store_true")
    parser.add_argument("--max-characters", type=int, default=4000)
    args = parser.parse_args()
    if args.holdout_pattern is None:
        args.holdout_pattern = ["*round7*.jsonl"]

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    holdout_label_rows = [row for row in labels if group_matches(str(row["label_file"]), args.holdout_pattern)]
    train_label_rows = [row for row in labels if not group_matches(str(row["label_file"]), args.holdout_pattern)]
    train_groups = sorted({str(row["label_file"]) for row in train_label_rows})
    train_labels_all = resolved_labels(train_label_rows)
    holdout_labels = resolved_labels(holdout_label_rows)
    all_rows = rows_for_labels(corpus, train_labels_all, "train") + rows_for_labels(corpus, holdout_labels, "holdout")
    ensure_features(all_rows, args.features, args.refresh_features, args.max_characters)

    feature_rows = read_feature_rows(args.features)
    by_id = {str(row["id"]): row for row in feature_rows}
    train_feature_rows = [by_id[row["id"]] for row in rows_for_labels(corpus, train_labels_all, "train") if row["id"] in by_id]
    holdout_feature_rows = [by_id[row["id"]] for row in rows_for_labels(corpus, holdout_labels, "holdout") if row["id"] in by_id]
    holdout_ids, holdout_x, holdout_y, holdout_rows = matrix(holdout_feature_rows)

    configs: list[tuple[float, str | None]] = [(0.1, None), (0.25, None), (0.5, None), (1.0, None), (2.0, None), (1.0, "balanced")]
    candidates: list[dict[str, Any]] = []
    group_summaries: list[tuple[str, int, int]] = []
    for c_value, class_weight in configs:
        oof_scores: list[float] = []
        oof_y: list[int] = []
        for group in train_groups:
            test_label_rows = [row for row in train_label_rows if str(row["label_file"]) == group]
            test_ids = {str(row["record_id"]) for row in test_label_rows}
            fit_label_rows = [row for row in train_label_rows if str(row["record_id"]) not in test_ids]
            fit_labels = resolved_labels(fit_label_rows)
            test_labels = resolved_labels(test_label_rows)
            fit_rows = [by_id[row["id"]] for row in rows_for_labels(corpus, fit_labels, "train") if row["id"] in by_id]
            test_rows = [by_id[row["id"]] for row in rows_for_labels(corpus, test_labels, "train") if row["id"] in by_id]
            if not fit_rows or not test_rows:
                continue
            _, fit_x, fit_y, _ = matrix(fit_rows)
            _, test_x, test_y, _ = matrix(test_rows)
            clf = model(c_value, class_weight)
            clf.fit(fit_x, fit_y)
            scores = clf.predict_proba(test_x)[:, 1]
            oof_scores.extend(map(float, scores))
            oof_y.extend(map(int, test_y))
            if c_value == configs[0][0] and class_weight == configs[0][1]:
                group_summaries.append((group, len(test_y), int(test_y.sum())))

        selected = best_metric(np.array(oof_y, dtype=np.int64), np.array(oof_scores, dtype=np.float64), args.precision_floor)
        candidates.append(
            {
                "c_value": c_value,
                "class_weight": class_weight,
                "threshold": selected["threshold"],
                "precision": selected["precision"],
                "recall": selected["recall"],
                "wake_rate": selected["wake_rate"],
                "tp": selected["tp"],
                "fp": selected["fp"],
                "fn": selected["fn"],
                "tn": selected["tn"],
                "oof_rows": len(oof_y),
            }
        )
        print(json.dumps(candidates[-1], sort_keys=True), flush=True)

    selected_config = max(
        candidates,
        key=lambda row: (
            1 if float(row["precision"]) >= args.precision_floor else 0,
            float(row["recall"]) if float(row["precision"]) >= args.precision_floor else float(row["precision"]),
            float(row["precision"]) if float(row["precision"]) >= args.precision_floor else float(row["recall"]),
        ),
    )

    _, train_x, train_y, _ = matrix(train_feature_rows)
    final = model(float(selected_config["c_value"]), selected_config["class_weight"])
    final.fit(train_x, train_y)
    holdout_scores = final.predict_proba(holdout_x)[:, 1]
    holdout_at_selected = metric_row(holdout_y, holdout_scores, float(selected_config["threshold"]))
    holdout_best = best_metric(holdout_y, holdout_scores, args.precision_floor)

    args.scores_output.parent.mkdir(parents=True, exist_ok=True)
    with args.scores_output.open("w") as handle:
        for record_id, row, label, score in zip(holdout_ids, holdout_rows, holdout_y, holdout_scores):
            handle.write(
                json.dumps(
                    {
                        "record_id": record_id,
                        "source": row.get("source"),
                        "label": int(label),
                        "score": float(score),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )

    lines = ["# NaturalLanguage Sentence Embedding Round-7 Report", ""]
    lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Features: `{args.features}`")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Train rows: {len(train_y)}")
    lines.append(f"Holdout rows: {len(holdout_y)}")
    lines.append(f"Holdout wake labels: {int(holdout_y.sum())}")
    lines.append("")
    lines.append("## Selected OOF Candidate")
    lines.append("")
    lines.append("| C | class weight | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    selected_display = {**selected_config, "class_weight_display": selected_config["class_weight"] or "none"}
    lines.append(
        "| {c_value:.2f} | {class_weight_display} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **selected_display,
        )
    )
    lines.append("")
    lines.append("## Round-7 Holdout")
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
    lines.append("## OOF Candidates")
    lines.append("")
    lines.append("| C | class weight | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in candidates:
        row_display = {**row, "class_weight_display": row["class_weight"] or "none"}
        lines.append(
            "| {c_value:.2f} | {class_weight_display} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row_display,
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
