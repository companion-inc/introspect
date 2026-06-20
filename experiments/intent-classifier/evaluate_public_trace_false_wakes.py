#!/usr/bin/env python3
"""Summarize false-wake risk on public coding-agent trace prompts."""

from __future__ import annotations

import argparse
import importlib.util
import json
from collections import Counter
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_INPUT = REPO / "feedback" / "intent-classifier" / "hf-agent-trace-prompts-expanded.jsonl"
DEFAULT_MODEL = Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json"
HOOK_SCORER = REPO / "hooks" / "intent_classifier.py"


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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--model", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()

    scorer = load_scorer()
    model = scorer.load_model(str(args.model))
    prefix_fields = model.get("text_prefix_fields")
    if not isinstance(prefix_fields, list):
        prefix_fields = None
    threshold = float(model.get("threshold", 0.5))

    scored: list[tuple[float, dict[str, Any]]] = []
    datasets: Counter[str] = Counter()
    for row in read_jsonl(args.input):
        datasets[str(row.get("dataset") or row.get("source") or "unknown")] += 1
        text = scorer.classifier_text(
            row.get("text", ""),
            source=row.get("source") or "unknown",
            old_trigger=bool(row.get("old_trigger")),
            matched_words=row.get("matched_words") or [],
            prefix_fields=prefix_fields,
        )
        scored.append((float(scorer.score_text(text, model)["score"]), row))

    sorted_scores = sorted(score for score, _ in scored)
    def quantile(q: float) -> float:
        if not sorted_scores:
            return 0.0
        index = min(len(sorted_scores) - 1, int(q * (len(sorted_scores) - 1)))
        return sorted_scores[index]

    lines = ["# Public Agent Trace False-Wake Eval", ""]
    lines.append(f"Model: {args.model}")
    lines.append(f"Model threshold: {threshold:.3f}")
    lines.append(f"Rows: {len(scored)}")
    lines.append("")
    lines.append("## Dataset Mix")
    lines.append("")
    lines.append("| dataset | rows |")
    lines.append("| --- | ---: |")
    for dataset, count in datasets.most_common():
        lines.append(f"| {dataset} | {count} |")
    lines.append("")
    lines.append("## Wake Counts")
    lines.append("")
    lines.append("| threshold | wake count | wake rate |")
    lines.append("| ---: | ---: | ---: |")
    for candidate in [0.30, 0.50, threshold, 0.80, 0.90, 0.95]:
        count = sum(score >= candidate for score, _ in scored)
        rate = count / len(scored) if scored else 0
        lines.append(f"| {candidate:.3f} | {count} | {rate:.4f} |")
    lines.append("")
    lines.append("## Score Quantiles")
    lines.append("")
    lines.append("| quantile | score |")
    lines.append("| ---: | ---: |")
    for q in [0, 0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99, 1.0]:
        lines.append(f"| {q:.2f} | {quantile(q):.6f} |")
    lines.append("")
    lines.append("## Highest Scored Public Prompts")
    lines.append("")
    lines.append("| score | dataset | row | text |")
    lines.append("| ---: | --- | ---: | --- |")
    for score, row in sorted(scored, reverse=True, key=lambda item: item[0])[:30]:
        text = " ".join(str(row.get("text", "")).split())[:180].replace("|", "\\|")
        lines.append(f"| {score:.6f} | {row.get('dataset') or ''} | {row.get('row_idx') or 0} | {text} |")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
