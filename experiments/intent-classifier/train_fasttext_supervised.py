#!/usr/bin/env python3
"""Train and evaluate compact fastText supervised wake-intent classifiers."""

from __future__ import annotations

import argparse
import fnmatch
import json
import tempfile
from pathlib import Path
from typing import Any

import fasttext
import numpy as np

from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    compact_text,
    label_rows,
    load_corpora,
    metric_row,
    resolved_labels,
    threshold_grid,
)


REPO = Path(__file__).resolve().parents[2]
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "fasttext-supervised-report.md"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "fasttext-supervised.bin"


def example_text(row: dict[str, Any]) -> str:
    return compact_text(f"source={row.get('source') or 'unknown'} {row.get('text') or ''}")


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def rows_for_labels(
    corpus: dict[str, dict[str, Any]],
    labels: dict[str, bool],
) -> tuple[list[dict[str, Any]], list[int]]:
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, should_wake in sorted(labels.items()):
        record = corpus.get(record_id)
        if not record:
            continue
        rows.append(record)
        y.append(int(should_wake))
    return rows, y


def write_fasttext_input(path: Path, rows: list[dict[str, Any]], y: list[int]) -> None:
    with path.open("w") as handle:
        for row, label in zip(rows, y):
            fasttext_label = "__label__wake" if label else "__label__nowake"
            handle.write(f"{fasttext_label} {example_text(row)}\n")


def score_rows(model: Any, rows: list[dict[str, Any]]) -> np.ndarray:
    scores: list[float] = []
    for row in rows:
        labels, probabilities = model.predict(example_text(row), k=2)
        score = 0.0
        for label, probability in zip(labels, probabilities):
            if label == "__label__wake":
                score = float(probability)
                break
        scores.append(score)
    return np.array(scores, dtype=np.float64)


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if viable:
        return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))
    return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"]), -float(row["wake_rate"])))


def result_sort_key(row: dict[str, Any], precision_floor: float) -> tuple[float, float, float, float]:
    if float(row["precision"]) >= precision_floor:
        return (1.0, float(row["recall"]), float(row["precision"]), -float(row["wake_rate"]))
    return (0.0, float(row["precision"]), float(row["recall"]), -float(row["wake_rate"]))


def parse_grid(value: str, cast: Any) -> list[Any]:
    return [cast(part) for part in value.split(",") if part]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--holdout-pattern", action="append", required=True)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--dims", default="16,32,64")
    parser.add_argument("--epochs", default="20,40")
    parser.add_argument("--lrs", default="0.05,0.10")
    parser.add_argument("--word-ngrams", default="1,2")
    parser.add_argument("--buckets", default="50000,100000")
    parser.add_argument("--min-count", type=int, default=1)
    parser.add_argument("--loss", default="softmax")
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    corpus = load_corpora([args.corpus])
    labels = label_rows(args.audit_dir)
    holdout_label_rows = [
        row for row in labels if group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    holdout_ids = {str(row["record_id"]) for row in holdout_label_rows}
    train_label_rows = [
        row
        for row in labels
        if str(row["record_id"]) not in holdout_ids
        and not group_matches(str(row["label_file"]), args.holdout_pattern)
    ]
    if not holdout_label_rows:
        raise SystemExit("Holdout pattern produced no labels")

    train_rows, train_y = rows_for_labels(corpus, resolved_labels(train_label_rows))
    holdout_rows, holdout_y = rows_for_labels(corpus, resolved_labels(holdout_label_rows))
    if len(set(train_y)) < 2:
        raise SystemExit("Need both train classes")
    if not holdout_rows:
        raise SystemExit("No holdout rows found")

    dims = parse_grid(args.dims, int)
    epochs = parse_grid(args.epochs, int)
    lrs = parse_grid(args.lrs, float)
    word_ngrams = parse_grid(args.word_ngrams, int)
    buckets = parse_grid(args.buckets, int)

    y_holdout = np.array(holdout_y, dtype=np.int64)
    evaluated: list[dict[str, Any]] = []
    best: dict[str, Any] | None = None
    best_model_path: Path | None = None

    with tempfile.TemporaryDirectory(prefix="introspect-fasttext-") as tmp:
        tmpdir = Path(tmp)
        train_path = tmpdir / "train.txt"
        write_fasttext_input(train_path, train_rows, train_y)

        for dim in dims:
            for epoch in epochs:
                for lr in lrs:
                    for word_ngram in word_ngrams:
                        for bucket in buckets:
                            model = fasttext.train_supervised(
                                input=str(train_path),
                                dim=dim,
                                epoch=epoch,
                                lr=lr,
                                wordNgrams=word_ngram,
                                minn=3,
                                maxn=6,
                                bucket=bucket,
                                minCount=args.min_count,
                                loss=args.loss,
                                verbose=0,
                            )
                            scores = score_rows(model, holdout_rows)
                            selected = best_at_precision(y_holdout, scores, args.precision_floor)
                            config = {
                                "dim": dim,
                                "epoch": epoch,
                                "lr": lr,
                                "wordNgrams": word_ngram,
                                "bucket": bucket,
                                "loss": args.loss,
                            }
                            row = {
                                "config": config,
                                "name": (
                                    f"dim={dim};epoch={epoch};lr={lr};"
                                    f"wordNgrams={word_ngram};bucket={bucket};loss={args.loss}"
                                ),
                                "threshold": selected["threshold"],
                                "precision": selected["precision"],
                                "recall": selected["recall"],
                                "wake_rate": selected["wake_rate"],
                                "tp": selected["tp"],
                                "fp": selected["fp"],
                                "fn": selected["fn"],
                                "tn": selected["tn"],
                            }
                            evaluated.append(row)
                            print(
                                json.dumps(
                                    {
                                        "candidate": row["name"],
                                        "precision": row["precision"],
                                        "recall": row["recall"],
                                        "threshold": row["threshold"],
                                    },
                                    sort_keys=True,
                                ),
                                flush=True,
                            )
                            if best is None or result_sort_key(row, args.precision_floor) > result_sort_key(best, args.precision_floor):
                                best = row
                                best_model_path = tmpdir / "best.bin"
                                model.save_model(str(best_model_path))

        if best is None or best_model_path is None:
            raise SystemExit("No candidate evaluated")
        args.model_output.parent.mkdir(parents=True, exist_ok=True)
        args.model_output.write_bytes(best_model_path.read_bytes())

    ranked = sorted(evaluated, key=lambda row: result_sort_key(row, args.precision_floor), reverse=True)
    model_size = args.model_output.stat().st_size if args.model_output.exists() else 0
    lines = ["# fastText Supervised Report", ""]
    lines.append(f"Holdout patterns: {', '.join(args.holdout_pattern)}")
    lines.append(f"Train rows: {len(train_rows)}")
    lines.append(f"Holdout rows: {len(holdout_rows)}")
    lines.append(f"Holdout wake labels: {sum(holdout_y)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Selected: `{best['name']}`")
    lines.append(f"Selected threshold: {float(best['threshold']):.3f}")
    lines.append(f"Model output: {args.model_output}")
    lines.append(f"Model bytes: {model_size}")
    lines.append("")
    lines.append("## Selected Holdout Metrics")
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
