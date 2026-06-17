#!/usr/bin/env python3
"""Compare subagent calibration labels with Qwen labels."""

from __future__ import annotations

import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_QWEN_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
]
DEFAULT_SUBAGENT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "subagent-calibration-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def qwen_by_id(paths: list[Path]) -> dict[str, dict[str, Any]]:
    labels: dict[str, dict[str, Any]] = {}
    for path in paths:
        for row in read_jsonl(path):
            if row.get("record_id"):
                labels[str(row["record_id"])] = row
    return labels


def subagent_rows(path: Path) -> list[tuple[str, dict[str, Any]]]:
    rows: list[tuple[str, dict[str, Any]]] = []
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            rows.append((label_file.name, row))
    return rows


def pct(value: int, total: int) -> str:
    return "0.0%" if total == 0 else f"{(value / total) * 100:.1f}%"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--qwen-labels", type=Path, nargs="*", default=DEFAULT_QWEN_LABELS)
    parser.add_argument("--subagent-dir", type=Path, default=DEFAULT_SUBAGENT_DIR)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    qwen = qwen_by_id(args.qwen_labels)
    rows = subagent_rows(args.subagent_dir)

    by_file: dict[str, Counter[str]] = defaultdict(Counter)
    disagreements: Counter[str] = Counter()
    compared = 0
    agree = 0
    missing_qwen = 0
    true_count = 0

    for filename, row in rows:
        should_wake = bool(row.get("should_wake"))
        if should_wake:
            true_count += 1
        by_file[filename]["rows"] += 1
        by_file[filename]["should_wake_true"] += int(should_wake)
        record_id = str(row.get("record_id") or "")
        qwen_row = qwen.get(record_id)
        if not qwen_row:
            missing_qwen += 1
            by_file[filename]["missing_qwen"] += 1
            continue
        compared += 1
        qwen_wake = bool(qwen_row.get("should_wake"))
        if should_wake == qwen_wake:
            agree += 1
            by_file[filename]["agree"] += 1
        else:
            pattern = f"subagent={should_wake} qwen={qwen_wake}"
            disagreements[pattern] += 1
            by_file[filename][pattern] += 1

    lines = [
        "# Subagent Calibration Report",
        "",
        f"Subagent labels: {len(rows)}",
        f"Subagent should_wake=true: {true_count} ({pct(true_count, len(rows))})",
        f"Comparable with Qwen: {compared}",
        f"Agreement on should_wake: {agree}/{compared} ({pct(agree, compared)})",
        f"Missing Qwen comparison labels: {missing_qwen}",
        "",
        "## By File",
        "",
    ]
    for filename, counts in sorted(by_file.items()):
        rows_count = counts["rows"]
        file_compared = rows_count - counts["missing_qwen"]
        file_agree = counts["agree"]
        lines.extend(
            [
                f"### {filename}",
                "",
                f"- rows: {rows_count}",
                f"- should_wake=true: {counts['should_wake_true']} ({pct(counts['should_wake_true'], rows_count)})",
                f"- agreement: {file_agree}/{file_compared} ({pct(file_agree, file_compared)})",
                f"- missing Qwen comparison labels: {counts['missing_qwen']}",
                "",
            ]
        )
        for pattern, count in sorted(counts.items()):
            if pattern.startswith("subagent="):
                lines.append(f"- disagreement {pattern}: {count}")
        if lines[-1] != "":
            lines.append("")

    lines.extend(["## Disagreement Patterns", ""])
    if disagreements:
        for pattern, count in disagreements.most_common():
            lines.append(f"- {pattern}: {count}")
    else:
        lines.append("- none")
    lines.append("")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines))
    print(args.report)


if __name__ == "__main__":
    main()
