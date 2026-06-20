#!/usr/bin/env python3
"""Batch-label Introspect intent examples with an OpenAI-compatible teacher endpoint."""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import json
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_INPUT = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl"

DEFAULT_ENDPOINT = "http://127.0.0.1:8000/v1/chat/completions"
DEFAULT_MODEL = "introspect-teacher"

SYSTEM_PROMPT = """You label user messages for Introspect, a local agent self-improvement system.

Return strict JSON only: {"labels":[...]}.

For each input record return exactly one object:
{
  "record_id": "...",
  "should_wake": boolean,
  "wake_probability": 0.0-1.0,
  "wake_label": "...",
  "route_label": "...",
  "confidence": 0.0-1.0,
  "reason": "short reason under 18 words"
}

Definitions:
- should_wake=true only when this user message is evidence that the agent/assistant workflow failed or needs durable improvement. Examples: the user says the agent did not test, did not read, ignored instructions, lost context, stopped too early, used the wrong tool, needs to keep going because prior work is incomplete, or asks why the agent behaved wrongly.
- should_wake=false for a normal task request, ordinary product/code feedback, quoted logs/code/transcripts, profanity used as an example, frustration at an external service, or emotional wording that is not about agent behavior.

wake_label values:
- agent_behavior_failure
- normal_task_request
- product_or_code_feedback
- external_system_vent
- quoted_or_pasted_context
- continuation_or_resume_pressure
- unclear

route_label values:
- no_change
- core_prompt
- project_prompt
- home_memory
- user_skill
- project_skill
- deterministic_hook_or_script
- needs_context

Routing rule:
Use route_label=no_change when should_wake=false.
Use needs_context when the text suggests an agent failure but the durable layer cannot be chosen from this message alone.
"""


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def existing_ids(path: Path) -> set[str]:
    if not path.exists():
        return set()
    ids: set[str] = set()
    with path.open() as handle:
        for raw in handle:
            try:
                row = json.loads(raw)
            except Exception:
                continue
            if row.get("error"):
                continue
            record_id = row.get("record_id")
            if record_id:
                ids.add(str(record_id))
    return ids


def compact_text(text: str, max_chars: int) -> str:
    return " ".join(str(text).split())[:max_chars]


def parse_json(content: str) -> dict[str, Any]:
    content = content.strip()
    if content.startswith("```"):
        content = content.strip("`").removeprefix("json").strip()
    start = content.find("{")
    end = content.rfind("}")
    if start >= 0 and end >= start:
        content = content[start:end + 1]
    return json.loads(content)


def labels_from_parsed(parsed: Any) -> list[dict[str, Any]]:
    if isinstance(parsed, dict) and isinstance(parsed.get("labels"), list):
        return [label for label in parsed["labels"] if isinstance(label, dict)]
    if isinstance(parsed, dict) and parsed.get("record_id"):
        return [parsed]
    if isinstance(parsed, list):
        return [label for label in parsed if isinstance(label, dict)]
    return []


def bounded_probability(value: Any, fallback: float) -> float:
    try:
        probability = float(value)
    except (TypeError, ValueError):
        probability = fallback
    if probability != probability:
        probability = fallback
    return min(max(probability, 0.0), 1.0)


def batch_rows(rows: list[dict[str, Any]], size: int) -> list[list[dict[str, Any]]]:
    return [rows[i:i + size] for i in range(0, len(rows), size)]


def label_batch(
    rows: list[dict[str, Any]],
    timeout: int,
    retries: int,
    max_chars: int,
    endpoint: str,
    model: str,
    system_prompt: str,
) -> list[dict[str, Any]]:
    records = [
        {
            "record_id": row["id"],
            "source": row.get("source"),
            "cwd": row.get("cwd"),
            "old_trigger": row.get("old_trigger"),
            "weak_label": row.get("weak_label"),
            "matched_words": row.get("matched_words", []),
            "text": compact_text(row.get("text", ""), max_chars),
        }
        for row in rows
    ]
    payload = {
        "model": model,
        "temperature": 0,
        "max_tokens": max(400, 150 * len(records)),
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": json.dumps({"records": records}, ensure_ascii=False)},
        ],
    }
    data = json.dumps(payload).encode()
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(
                endpoint,
                data=data,
                headers={"Content-Type": "application/json"},
            )
            response = urllib.request.urlopen(request, timeout=timeout)
            body = json.loads(response.read().decode())
            content = body["choices"][0]["message"]["content"]
            parsed = parse_json(content)
            labels = labels_from_parsed(parsed)
            if not labels:
                raise ValueError("missing labels")
            by_id = {str(label.get("record_id")): label for label in labels if isinstance(label, dict)}
            results: list[dict[str, Any]] = []
            for row in rows:
                label = by_id.get(str(row["id"]))
                if label is None and len(rows) == 1 and len(labels) == 1:
                    label = labels[0]
                if not label:
                    raise ValueError(f"missing label for {row['id']}")
                raw_should_wake = label.get("should_wake")
                raw_probability = label.get("wake_probability")
                if isinstance(raw_should_wake, bool):
                    should_wake = raw_should_wake
                    fallback_probability = 0.85 if should_wake else 0.15
                else:
                    fallback_probability = bounded_probability(raw_probability, 0.5)
                    should_wake = fallback_probability >= 0.5
                wake_probability = bounded_probability(raw_probability, fallback_probability)
                confidence = bounded_probability(label.get("confidence"), max(wake_probability, 1.0 - wake_probability))
                results.append(
                    {
                        "record_id": row["id"],
                        "source": row.get("source"),
                        "locator": row.get("locator"),
                        "old_trigger": row.get("old_trigger"),
                        "weak_label": row.get("weak_label"),
                        "wake_label": label.get("wake_label"),
                        "route_label": label.get("route_label"),
                        "should_wake": should_wake,
                        "wake_probability": wake_probability,
                        "confidence": confidence,
                        "reason": str(label.get("reason") or "")[:240],
                    }
                )
            return results
        except Exception as exc:
            if attempt >= retries:
                return [
                    {
                        "record_id": row["id"],
                        "source": row.get("source"),
                        "locator": row.get("locator"),
                        "old_trigger": row.get("old_trigger"),
                        "weak_label": row.get("weak_label"),
                        "error": f"{type(exc).__name__}: {str(exc)[:240]}",
                    }
                    for row in rows
                ]
            time.sleep(1.5 * (attempt + 1))
    raise AssertionError("unreachable")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=8)
    parser.add_argument("--batch-size", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--max-chars", type=int, default=1200)
    parser.add_argument("--progress-every", type=int, default=1000)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--system-prompt-file", type=Path)
    args = parser.parse_args()

    system_prompt = SYSTEM_PROMPT
    if args.system_prompt_file:
        system_prompt = args.system_prompt_file.read_text()

    done = existing_ids(args.output)
    rows = [row for row in read_jsonl(args.input) if row["id"] not in done]
    if args.limit:
        rows = rows[:args.limit]
    batches = batch_rows(rows, args.batch_size)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    written = 0
    with args.output.open("a") as out:
        with futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            future_map = {
                executor.submit(
                    label_batch,
                    batch,
                    args.timeout,
                    args.retries,
                    args.max_chars,
                    args.endpoint,
                    args.model,
                    system_prompt,
                ): batch
                for batch in batches
            }
            for future in futures.as_completed(future_map):
                results = future.result()
                with lock:
                    for result in results:
                        out.write(json.dumps(result, ensure_ascii=False) + "\n")
                        written += 1
                    out.flush()
                    if args.progress_every > 0 and written % args.progress_every < len(results):
                        print(f"labeled {written}/{len(rows)}", flush=True)
    print(json.dumps({"input": str(args.input), "output": str(args.output), "new_labels": written, "already_done": len(done)}, sort_keys=True))


if __name__ == "__main__":
    main()
