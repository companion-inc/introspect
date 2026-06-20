#!/usr/bin/env python3
"""Leave-one-round-out search over exported wake-classifier ensembles."""

from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "exported-model-ensemble-loro-report.md"
HOOK_SCORER = REPO / "hooks" / "intent_classifier.py"

DEFAULT_MODEL_SPECS = [
    ("production-v2", Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json"),
    ("round8-retrain", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round8-holdout-selected.json"),
    ("round9-retrain", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round9-holdout-selected.json"),
    ("round8-after-round9", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round8-after-round9-selected.json"),
    ("round9-distill", REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student-round9-qwen-labels-w005.json"),
]

DEFAULT_GROUPS = [
    ("round4", "*round4*.jsonl"),
    ("round5", "*round5*.jsonl"),
    ("round6", "*round6*.jsonl"),
    ("round7", "*round7*.jsonl"),
    ("round8", "*round8*.jsonl"),
    ("round9", "*round9*.jsonl"),
]


@dataclass(frozen=True)
class Rule:
    name: str
    kind: str
    model_indices: tuple[int, ...]
    thresholds: tuple[float, ...]


def load_scorer():
    spec = importlib.util.spec_from_file_location("intent_classifier", HOOK_SCORER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load {HOOK_SCORER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def resolved_labels(paths: list[Path]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for path in paths:
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id:
                votes.setdefault(str(record_id), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def parse_model_spec(raw: str) -> tuple[str, Path]:
    if "=" not in raw:
        path = Path(raw)
        return path.stem, path
    name, path = raw.split("=", 1)
    return name, Path(path)


def parse_group_spec(raw: str) -> tuple[str, str]:
    if "=" not in raw:
        return raw, raw
    name, pattern = raw.split("=", 1)
    return name, pattern


def metric(y: np.ndarray, pred: np.ndarray) -> dict[str, float | int]:
    tp = int(((pred == 1) & (y == 1)).sum())
    fp = int(((pred == 1) & (y == 0)).sum())
    fn = int(((pred == 0) & (y == 1)).sum())
    tn = int(((pred == 0) & (y == 0)).sum())
    return {
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y) if len(y) else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def apply_rule(scores: np.ndarray, rule: Rule) -> np.ndarray:
    cols = scores[:, rule.model_indices]
    if rule.kind == "single":
        return cols[:, 0] >= rule.thresholds[0]
    if rule.kind == "mean":
        return cols.mean(axis=1) >= rule.thresholds[0]
    if rule.kind == "max":
        return cols.max(axis=1) >= rule.thresholds[0]
    if rule.kind == "min":
        return cols.min(axis=1) >= rule.thresholds[0]
    if rule.kind == "and":
        return np.logical_and.reduce([cols[:, index] >= threshold for index, threshold in enumerate(rule.thresholds)])
    if rule.kind == "or":
        return np.logical_or.reduce([cols[:, index] >= threshold for index, threshold in enumerate(rule.thresholds)])
    raise ValueError(f"unknown rule kind: {rule.kind}")


def rule_label(rule: Rule, model_names: list[str]) -> str:
    names = [model_names[index] for index in rule.model_indices]
    thresholds = ",".join(f"{value:.3f}" for value in rule.thresholds)
    return f"{rule.kind}({','.join(names)};t={thresholds})"


def generate_rules(model_names: list[str], thresholds: list[float]) -> list[Rule]:
    rules: list[Rule] = []
    for index, name in enumerate(model_names):
        for threshold in thresholds:
            rules.append(Rule(f"single:{name}:{threshold:.3f}", "single", (index,), (threshold,)))
    for left, right in itertools.combinations(range(len(model_names)), 2):
        for threshold in thresholds:
            rules.append(Rule(f"mean:{left}:{right}:{threshold:.3f}", "mean", (left, right), (threshold,)))
            rules.append(Rule(f"max:{left}:{right}:{threshold:.3f}", "max", (left, right), (threshold,)))
            rules.append(Rule(f"min:{left}:{right}:{threshold:.3f}", "min", (left, right), (threshold,)))
        for left_threshold in thresholds:
            for right_threshold in thresholds:
                rules.append(
                    Rule(
                        f"and:{left}:{right}:{left_threshold:.3f}:{right_threshold:.3f}",
                        "and",
                        (left, right),
                        (left_threshold, right_threshold),
                    )
                )
                rules.append(
                    Rule(
                        f"or:{left}:{right}:{left_threshold:.3f}:{right_threshold:.3f}",
                        "or",
                        (left, right),
                        (left_threshold, right_threshold),
                    )
                )
    return rules


def sort_key(row: dict[str, Any], precision_floor: float) -> tuple[float, float, float, float]:
    if float(row["precision"]) >= precision_floor:
        return (1.0, float(row["recall"]), float(row["precision"]), -float(row["wake_rate"]))
    return (0.0, float(row["precision"]), float(row["recall"]), -float(row["wake_rate"]))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--model", action="append", default=[])
    parser.add_argument("--group", action="append", default=[])
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    model_specs = [parse_model_spec(raw) for raw in args.model]
    if not model_specs:
        model_specs = [(name, path) for name, path in DEFAULT_MODEL_SPECS if path.exists()]
    group_specs = [parse_group_spec(raw) for raw in args.group] or DEFAULT_GROUPS
    model_names = [name for name, _ in model_specs]

    scorer = load_scorer()
    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    models = [(name, path, scorer.load_model(str(path))) for name, path in model_specs]

    examples: list[dict[str, Any]] = []
    for group_name, pattern in group_specs:
        labels = resolved_labels(sorted(args.label_dir.glob(pattern)))
        for record_id, should_wake in labels.items():
            row = corpus.get(record_id)
            if not row:
                continue
            scores: list[float] = []
            for _, _, model in models:
                prefix_fields = model.get("text_prefix_fields")
                if not isinstance(prefix_fields, list):
                    prefix_fields = None
                text = scorer.classifier_text(
                    row.get("text", ""),
                    source=row.get("source") or "unknown",
                    old_trigger=bool(row.get("old_trigger")),
                    matched_words=row.get("matched_words") or [],
                    prefix_fields=prefix_fields,
                )
                scores.append(float(scorer.score_text(text, model)["score"]))
            examples.append({"id": record_id, "group": group_name, "y": int(should_wake), "scores": scores})

    groups = sorted({row["group"] for row in examples})
    y = np.array([row["y"] for row in examples], dtype=np.int64)
    score_matrix = np.array([row["scores"] for row in examples], dtype=np.float64)
    group_array = np.array([row["group"] for row in examples])
    thresholds = [round(value / 1000, 3) for value in range(200, 951, 25)]
    rules = generate_rules(model_names, thresholds)

    fold_rows: list[dict[str, Any]] = []
    aggregate_pred = np.zeros_like(y, dtype=bool)
    for group in groups:
        train_mask = group_array != group
        test_mask = group_array == group
        best_rule: Rule | None = None
        best_train: dict[str, Any] | None = None
        for rule in rules:
            pred_train = apply_rule(score_matrix[train_mask], rule)
            train_metric = metric(y[train_mask], pred_train)
            if best_train is None or sort_key(train_metric, args.precision_floor) > sort_key(best_train, args.precision_floor):
                best_train = train_metric
                best_rule = rule
        if best_rule is None or best_train is None:
            raise SystemExit("No ensemble rule selected")
        pred_test = apply_rule(score_matrix[test_mask], best_rule)
        aggregate_pred[test_mask] = pred_test
        test_metric = metric(y[test_mask], pred_test)
        fold_rows.append(
            {
                "group": group,
                "rule": rule_label(best_rule, model_names),
                "train": best_train,
                "test": test_metric,
            }
        )

    aggregate = metric(y, aggregate_pred)
    lines = ["# Exported Model Ensemble LORO Report", ""]
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Examples: {len(y)}")
    lines.append(f"Positive labels: {int(y.sum())}")
    lines.append("")
    lines.append("## Holdout")
    lines.append("")
    lines.append("| metric | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| loro selected | 0.000 | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **aggregate
        )
    )
    lines.append("")
    lines.append("## Folds")
    lines.append("")
    lines.append("| held-out group | rule selected on other groups | train precision | train recall | test precision | test recall | TP | FP | FN | TN |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in fold_rows:
        test = row["test"]
        train = row["train"]
        lines.append(
            "| {group} | `{rule}` | {train_precision:.4f} | {train_recall:.4f} | {test_precision:.4f} | {test_recall:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                group=row["group"],
                rule=row["rule"],
                train_precision=float(train["precision"]),
                train_recall=float(train["recall"]),
                test_precision=float(test["precision"]),
                test_recall=float(test["recall"]),
                tp=int(test["tp"]),
                fp=int(test["fp"]),
                fn=int(test["fn"]),
                tn=int(test["tn"]),
            )
        )

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
