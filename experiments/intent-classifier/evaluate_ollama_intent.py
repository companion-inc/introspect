#!/usr/bin/env python3
"""Evaluate a local Ollama model as a private wake-intent judge."""

from __future__ import annotations

import argparse
import json
import time
import urllib.error
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "ollama-gemma3-270m-round8-report.md"
DEFAULT_PREDICTIONS = REPO / "feedback" / "intent-classifier" / "ollama-gemma3-270m-round8-predictions.jsonl"


PROMPT = """You are a private local classifier for an agent-feedback system.

Return JSON only: {{"wake": true|false, "reason": "short"}}.

wake=true only when the user's message is about the AI agent's own bad behavior, process failure, refusal to continue, ignored instructions, wrong tool/file/repo, shallow work, or needing recovery from a bad agent run.

wake=false for ordinary coding/product instructions, normal requests to read/test/fix/continue, pasted context, quoted examples, external-system bugs, or general task details.

Message:
{text}
"""


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
            if record_id and isinstance(row.get("should_wake"), bool):
                votes.setdefault(str(record_id), []).append(bool(row["should_wake"]))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def compact(text: str, limit: int) -> str:
    return " ".join(str(text).split())[:limit]


def ollama_generate(host: str, model: str, prompt: str, timeout: float) -> dict[str, Any]:
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "format": "json",
        "keep_alive": "10m",
        "options": {
            "temperature": 0,
            "num_predict": 48,
            "top_k": 1,
        },
    }
    request = urllib.request.Request(
        f"{host.rstrip('/')}/api/generate",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def parse_response(text: str) -> tuple[bool | None, str]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        start = text.find("{")
        end = text.rfind("}")
        if start < 0 or end < start:
            return None, "invalid_json"
        try:
            data = json.loads(text[start:end + 1])
        except json.JSONDecodeError:
            return None, "invalid_json"
    wake = data.get("wake")
    if isinstance(wake, bool):
        return wake, str(data.get("reason") or "")
    return None, "missing_bool"


def metric(rows: list[dict[str, Any]]) -> dict[str, float | int]:
    tp = fp = fn = tn = invalid = 0
    for row in rows:
        truth = bool(row["label"])
        pred = row.get("prediction")
        if not isinstance(pred, bool):
            invalid += 1
            pred = False
        if pred and truth:
            tp += 1
        elif pred and not truth:
            fp += 1
        elif not pred and truth:
            fn += 1
        else:
            tn += 1
    total = len(rows)
    return {
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / total if total else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
        "invalid": invalid,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-file", type=Path, action="append", required=True)
    parser.add_argument("--model", default="gemma3:270m")
    parser.add_argument("--host", default="http://127.0.0.1:11434")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--predictions", type=Path, default=DEFAULT_PREDICTIONS)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--text-limit", type=int, default=1600)
    parser.add_argument("--timeout", type=float, default=60.0)
    args = parser.parse_args()

    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = resolved_labels(args.label_file)
    record_ids = sorted(labels)
    if args.limit > 0:
        record_ids = record_ids[: args.limit]

    rows: list[dict[str, Any]] = []
    args.predictions.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with args.predictions.open("w") as handle:
        for index, record_id in enumerate(record_ids, 1):
            row = corpus.get(record_id)
            if not row:
                continue
            prompt = PROMPT.format(text=compact(row.get("text") or "", args.text_limit))
            item_started = time.monotonic()
            try:
                result = ollama_generate(args.host, args.model, prompt, args.timeout)
                prediction, reason = parse_response(str(result.get("response") or ""))
                error = ""
            except (urllib.error.URLError, TimeoutError, OSError) as exc:
                prediction, reason, error = None, "", f"{type(exc).__name__}: {exc}"
            elapsed = time.monotonic() - item_started
            output = {
                "record_id": record_id,
                "label": int(labels[record_id]),
                "prediction": prediction,
                "reason": reason,
                "source": row.get("source"),
                "elapsed_seconds": elapsed,
                "error": error,
            }
            rows.append(output)
            handle.write(json.dumps(output, ensure_ascii=False) + "\n")
            if index % 25 == 0:
                print(json.dumps({"processed": index, **metric(rows)}), flush=True)

    metrics = metric(rows)
    total_elapsed = time.monotonic() - started
    lines = ["# Ollama Intent Judge Report", ""]
    lines.append(f"Model: `{args.model}`")
    lines.append(f"Label files: {', '.join(path.name for path in args.label_file)}")
    lines.append(f"Rows: {len(rows)}")
    lines.append(f"Positive wake labels: {sum(int(row['label']) for row in rows)}")
    lines.append(f"Total seconds: {total_elapsed:.2f}")
    lines.append(f"Average seconds per row: {(total_elapsed / len(rows)) if rows else 0:.3f}")
    lines.append("")
    lines.append("## Metrics")
    lines.append("")
    lines.append("| precision | recall | wake rate | TP | FP | FN | TN | invalid |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} | {invalid} |".format(
            **metrics
        )
    )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
