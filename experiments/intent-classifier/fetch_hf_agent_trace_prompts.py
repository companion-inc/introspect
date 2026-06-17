#!/usr/bin/env python3
"""Fetch prompt rows from Hugging Face agent-trace datasets."""

from __future__ import annotations

import argparse
import json
import ssl
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "hf-agent-trace-prompts.jsonl"
DATASETS = [
    "badlogicgames/pi-mono",
    "badlogicgames/pi-diff-review",
    "clem/hf-coding-tools-traces",
    "championswimmer/pi-coding-sessions",
    "TeichAI/DeepSeek-v4-Pro-Agent",
]
BASE_URL = "https://datasets-server.huggingface.co"

try:
    import certifi  # type: ignore
except Exception:  # pragma: no cover - depends on local Python bundle
    certifi = None

SSL_CONTEXT = (
    ssl.create_default_context(cafile=certifi.where())
    if certifi is not None
    else ssl._create_unverified_context()
)


def compact_text(text: str, max_chars: int) -> str:
    return " ".join(str(text).split())[:max_chars]


def get_json(url: str, timeout: int = 60) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "introspect-intent-v2/1.0"})
    with urllib.request.urlopen(request, timeout=timeout, context=SSL_CONTEXT) as response:
        return json.loads(response.read().decode())


def rows_url(dataset: str, config: str, split: str, offset: int, length: int) -> str:
    params = urllib.parse.urlencode(
        {
            "dataset": dataset,
            "config": config,
            "split": split,
            "offset": offset,
            "length": length,
        }
    )
    return f"{BASE_URL}/rows?{params}"


def first_rows_url(dataset: str, config: str, split: str) -> str:
    params = urllib.parse.urlencode({"dataset": dataset, "config": config, "split": split})
    return f"{BASE_URL}/first-rows?{params}"


def append_viewer_rows(records: list[dict[str, Any]], dataset: str, config: str, split: str, rows: list[dict[str, Any]], max_chars: int) -> None:
    for item in rows:
        row = item.get("row") or {}
        prompt = compact_text(row.get("prompt") or "", max_chars)
        if not prompt:
            continue
        records.append(
            {
                "id": f"hf:{dataset}:{config}:{split}:{item.get('row_idx', len(records))}",
                "source": f"hf_agent_trace:{dataset}",
                "dataset": dataset,
                "config": config,
                "split": split,
                "row_idx": item.get("row_idx"),
                "locator": f"https://huggingface.co/datasets/{dataset}",
                "harness": row.get("harness"),
                "session_id": row.get("session_id"),
                "sent_at": row.get("sent_at"),
                "num_user_messages": row.get("num_user_messages"),
                "num_tool_calls": row.get("num_tool_calls"),
                "text": prompt,
                "old_trigger": False,
                "matched_words": [],
                "weak_label": "hf_agent_trace_prompt",
                "weak_categories": ["hf_agent_trace_prompt"],
            }
        )


def splits_for(dataset: str) -> list[tuple[str, str]]:
    params = urllib.parse.urlencode({"dataset": dataset})
    body = get_json(f"{BASE_URL}/splits?{params}")
    return [
        (str(row["config"]), str(row["split"]))
        for row in body.get("splits", [])
        if row.get("config") and row.get("split")
    ]


def iter_dataset_rows(dataset: str, limit: int, page_size: int) -> list[dict[str, Any]]:
    records: list[dict[str, Any]] = []
    for config, split in splits_for(dataset):
        offset = 0
        while len(records) < limit:
            try:
                body = get_json(rows_url(dataset, config, split, offset, page_size))
            except Exception:
                if offset != 0:
                    raise
                body = get_json(first_rows_url(dataset, config, split))
            rows = body.get("rows") or []
            if not rows:
                break
            append_viewer_rows(records, dataset, config, split, rows, 2400)
            records = records[:limit]
            offset += len(rows)
            if body.get("partial") or len(rows) < page_size:
                break
            time.sleep(0.1)
    return records[:limit]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--dataset", action="append", dest="datasets")
    parser.add_argument("--per-dataset", type=int, default=400)
    parser.add_argument("--page-size", type=int, default=100)
    args = parser.parse_args()

    datasets = args.datasets or DATASETS
    all_rows: list[dict[str, Any]] = []
    errors: dict[str, str] = {}
    for dataset in datasets:
        try:
            rows = iter_dataset_rows(dataset, args.per_dataset, args.page_size)
            all_rows.extend(rows)
            print(json.dumps({"dataset": dataset, "rows": len(rows)}, sort_keys=True), flush=True)
        except Exception as exc:
            errors[dataset] = f"{type(exc).__name__}: {str(exc)[:240]}"
            print(json.dumps({"dataset": dataset, "error": errors[dataset]}, sort_keys=True), flush=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as handle:
        for row in all_rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(json.dumps({"output": str(args.output), "rows": len(all_rows), "errors": errors}, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
