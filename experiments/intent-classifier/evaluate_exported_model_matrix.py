#!/usr/bin/env python3
"""Compare exported wake classifiers across hard-label groups."""

from __future__ import annotations

import argparse
import importlib.util
import json
from collections import Counter
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "exported-model-hard-round-matrix-report.md"
HOOK_SCORER = REPO / "hooks" / "intent_classifier.py"

DEFAULT_MODEL_SPECS = [
    ("production-v2", Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json"),
    ("round8-retrain", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round8-holdout-selected.json"),
    ("round9-retrain", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round9-holdout-selected.json"),
    ("round8-after-round9", REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round8-after-round9-selected.json"),
    ("round9-distill", REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student-round9-qwen-labels-w005.json"),
    ("qwen36-35b-distill", REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student-qwen36-35b-nvfp4-round10.json"),
]

DEFAULT_GROUPS = [
    ("round4", "*round4*.jsonl"),
    ("round5", "*round5*.jsonl"),
    ("round6", "*round6*.jsonl"),
    ("round7", "*round7*.jsonl"),
    ("round8", "*round8*.jsonl"),
    ("round9", "*round9*.jsonl"),
]


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


def metric_row(y_true: list[int], scores: list[float], threshold: float) -> dict[str, float | int]:
    tp = fp = fn = tn = 0
    for truth, score in zip(y_true, scores):
        pred = score >= threshold
        if pred and truth:
            tp += 1
        elif pred and not truth:
            fp += 1
        elif not pred and truth:
            fn += 1
        else:
            tn += 1
    return {
        "threshold": threshold,
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if y_true else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


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


def score_group(scorer: Any, model: dict[str, Any], corpus: dict[str, dict[str, Any]], labels: dict[str, bool]) -> tuple[list[int], list[float], int]:
    prefix_fields = model.get("text_prefix_fields")
    if not isinstance(prefix_fields, list):
        prefix_fields = None
    y: list[int] = []
    scores: list[float] = []
    missing = 0
    for record_id, should_wake in labels.items():
        row = corpus.get(record_id)
        if not row:
            missing += 1
            continue
        text = scorer.classifier_text(
            row.get("text", ""),
            source=row.get("source") or "unknown",
            old_trigger=bool(row.get("old_trigger")),
            matched_words=row.get("matched_words") or [],
            prefix_fields=prefix_fields,
        )
        result = scorer.score_text(text, model)
        y.append(int(should_wake))
        scores.append(float(result["score"]))
    return y, scores, missing


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--model", action="append", default=[])
    parser.add_argument("--group", action="append", default=[])
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    model_specs = [parse_model_spec(raw) for raw in args.model]
    if not model_specs:
        model_specs = [(name, path) for name, path in DEFAULT_MODEL_SPECS if path.exists()]
    group_specs = [parse_group_spec(raw) for raw in args.group] or DEFAULT_GROUPS

    scorer = load_scorer()
    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}

    group_labels: dict[str, dict[str, bool]] = {}
    group_files: dict[str, list[Path]] = {}
    for group_name, pattern in group_specs:
        files = sorted(args.label_dir.glob(pattern))
        labels = resolved_labels(files)
        if labels:
            group_labels[group_name] = labels
            group_files[group_name] = files

    model_meta: list[dict[str, Any]] = []
    results: list[dict[str, Any]] = []
    for model_name, path in model_specs:
        model = scorer.load_model(str(path))
        threshold = float(model.get("threshold", 0.5))
        report = model.get("report") if isinstance(model.get("report"), dict) else {}
        model_meta.append(
            {
                "name": model_name,
                "path": str(path),
                "threshold": threshold,
                "export_includes_holdout": report.get("export_includes_holdout"),
                "export_holdout_patterns": report.get("export_holdout_patterns") or [],
            }
        )
        for group_name, labels in group_labels.items():
            y, scores, missing = score_group(scorer, model, corpus, labels)
            metrics = metric_row(y, scores, threshold)
            results.append(
                {
                    "model": model_name,
                    "model_path": str(path),
                    "group": group_name,
                    "rows": len(y),
                    "positives": sum(y),
                    "missing": missing,
                    **metrics,
                }
            )

    lines = ["# Exported Model Hard-Round Matrix", ""]
    lines.append(f"Corpus: `{args.corpus}`")
    lines.append(f"Label dir: `{args.label_dir}`")
    lines.append("")
    lines.append("## Models")
    lines.append("")
    lines.append("| model | threshold | export includes holdout | export holdout patterns | path |")
    lines.append("| --- | ---: | --- | --- | --- |")
    for row in model_meta:
        holdout = row["export_includes_holdout"]
        holdout_text = "unknown" if holdout is None else str(bool(holdout))
        patterns = ", ".join(map(str, row["export_holdout_patterns"])) or ""
        lines.append(f"| {row['name']} | {row['threshold']:.3f} | {holdout_text} | {patterns} | `{row['path']}` |")
    lines.append("")
    lines.append("## Groups")
    lines.append("")
    lines.append("| group | files | rows | positives |")
    lines.append("| --- | ---: | ---: | ---: |")
    for group_name in group_labels:
        labels = group_labels[group_name]
        lines.append(
            f"| {group_name} | {len(group_files[group_name])} | {len(labels)} | {sum(labels.values())} |"
        )
    lines.append("")
    lines.append("## Matrix At Each Model Threshold")
    lines.append("")
    lines.append("| model | group | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in results:
        lines.append(
            "| {model} | {group} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Macro Summary")
    lines.append("")
    lines.append("| model | groups | mean precision | mean recall | total TP | total FP | total FN | total TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    by_model: dict[str, list[dict[str, Any]]] = {}
    for row in results:
        by_model.setdefault(str(row["model"]), []).append(row)
    for model_name, rows in by_model.items():
        mean_precision = sum(float(row["precision"]) for row in rows) / len(rows)
        mean_recall = sum(float(row["recall"]) for row in rows) / len(rows)
        lines.append(
            "| {model} | {groups} | {precision:.4f} | {recall:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                model=model_name,
                groups=len(rows),
                precision=mean_precision,
                recall=mean_recall,
                tp=sum(int(row["tp"]) for row in rows),
                fp=sum(int(row["fp"]) for row in rows),
                fn=sum(int(row["fn"]) for row in rows),
                tn=sum(int(row["tn"]) for row in rows),
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
