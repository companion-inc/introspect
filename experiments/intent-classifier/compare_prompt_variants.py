#!/usr/bin/env python3
"""Compare Qwen prompt variants against subagent audit labels."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "prompt-variant-audit-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def audit_rows(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            if row.get("record_id"):
                merged = dict(row)
                merged["audit_file"] = label_file.name
                rows.append(merged)
    return rows


def label_map(path: Path) -> dict[str, bool]:
    return {
        str(row["record_id"]): bool(row.get("should_wake"))
        for row in read_jsonl(path)
        if row.get("record_id") and not row.get("error")
    }


def metrics(y_true: list[bool], y_pred: list[bool]) -> dict[str, float | int]:
    tp = sum(1 for true, pred in zip(y_true, y_pred) if true and pred)
    fp = sum(1 for true, pred in zip(y_true, y_pred) if not true and pred)
    fn = sum(1 for true, pred in zip(y_true, y_pred) if true and not pred)
    tn = sum(1 for true, pred in zip(y_true, y_pred) if not true and not pred)
    total = len(y_true)
    return {
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "accuracy": (tp + tn) / total if total else 0.0,
        "wake_rate": (tp + fp) / total if total else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--variant", action="append", nargs=2, metavar=("NAME", "PATH"), required=True)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    audit = audit_rows(args.audit_dir)
    variants = {name: label_map(Path(path)) for name, path in args.variant}
    common_rows = [
        row
        for row in audit
        if all(str(row["record_id"]) in labels for labels in variants.values())
    ]
    common_ids = [str(row["record_id"]) for row in common_rows]
    y_true = [bool(row.get("should_wake")) for row in common_rows]

    predictions: dict[str, list[bool]] = {
        name: [labels[record_id] for record_id in common_ids]
        for name, labels in variants.items()
    }

    names = list(predictions)
    if len(names) >= 2:
        predictions[f"{names[0]}_OR_{names[1]}"] = [
            predictions[names[0]][index] or predictions[names[1]][index]
            for index in range(len(common_ids))
        ]
        predictions[f"{names[0]}_AND_{names[1]}"] = [
            predictions[names[0]][index] and predictions[names[1]][index]
            for index in range(len(common_ids))
        ]
    if len(names) >= 3:
        predictions["majority"] = [
            sum(int(predictions[name][index]) for name in names) >= 2
            for index in range(len(common_ids))
        ]
        predictions["any_variant"] = [
            any(predictions[name][index] for name in names)
            for index in range(len(common_ids))
        ]
        predictions["all_variants"] = [
            all(predictions[name][index] for name in names)
            for index in range(len(common_ids))
        ]

    lines = ["# Prompt Variant Audit Report", ""]
    lines.append(f"Audit decisions compared: {len(common_ids)}")
    lines.append(f"Audit positives: {sum(y_true)}")
    lines.append("")
    lines.append("| variant | precision | recall | accuracy | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, y_pred in predictions.items():
        row = metrics(y_true, y_pred)
        lines.append(
            "| {name} | {precision:.2f} | {recall:.2f} | {accuracy:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                name=name,
                **row,
            )
        )

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
