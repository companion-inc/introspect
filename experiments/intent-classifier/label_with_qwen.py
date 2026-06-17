#!/usr/bin/env python3
"""Label Introspect intent examples with the local DGX vLLM Qwen endpoint."""

from __future__ import annotations

import argparse
import concurrent.futures as futures
import json
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_INPUT = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl"

ENDPOINT = "http://127.0.0.1:8000/v1/chat/completions"
MODEL = "qwen"

BASELINE_SYSTEM_PROMPT = """You label user messages for Introspect, a local agent self-improvement system.

Return strict JSON only.

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

JSON schema:
{
  "should_wake": boolean,
  "wake_label": "...",
  "route_label": "...",
  "confidence": 0.0-1.0,
  "reason": "short reason under 18 words"
}
"""

FAST_BALANCED_SYSTEM_PROMPT = """Return strict JSON for Introspect wake-gate labeling.

should_wake=true only when the user's target is the agent/assistant workflow failing: did not test/read/search/verify/label/train/continue, ignored instructions, lost context, stopped early, used wrong tool/layer, failed to use requested machine/subagents/tools, or asks why the agent behaved badly. Hostile wording still wakes when it contains a concrete agent-process failure.

should_wake=false when the target is product/app/code/external context: normal tasks, UI/graph/diff/classifier/model requests, product/code feedback, pasted logs/transcripts/examples, external venting, or profanity/anger without a concrete agent-process failure.

Use route_label=no_change when should_wake=false. Use needs_context when should_wake=true but the durable layer is unclear.

wake_label: agent_behavior_failure, normal_task_request, product_or_code_feedback, external_system_vent, quoted_or_pasted_context, continuation_or_resume_pressure, unclear.
route_label: no_change, core_prompt, project_prompt, home_memory, user_skill, project_skill, deterministic_hook_or_script, needs_context.

JSON schema: {"should_wake": boolean, "wake_label": "...", "route_label": "...", "confidence": 0.0-1.0, "reason": "under 18 words"}
"""

STRICT_SYSTEM_PROMPT = """You label user messages for Introspect, a local agent self-improvement system.

Return strict JSON only.

Primary decision:
- should_wake=true only when the user is criticizing, correcting, debugging, or pressuring the agent/assistant workflow itself.
- should_wake=false when the user is asking for product/code work, describing a desired app feature, giving ordinary product feedback, pasting logs/code/transcripts, venting about an external system/person, or using hostile/profane wording without a concrete agent-workflow failure.

The key distinction is target:
- Agent/workflow target => can wake. Examples: did not test, did not read, ignored instructions, misunderstood the goal, lost context, stopped too early, failed to use available tools, used the wrong tool/layer, needs to keep going because the agent's current work is incomplete, asks why the agent behaved wrongly.
- Product/app/code target => no wake. Examples: asking to add graphs, change UI, train a classifier, improve a feature, inspect diffs, run a normal experiment, or explain how an app works.
- Quoted/pasted context => no wake unless the user's own current instruction outside the quote says the agent failed.

Do not wake just because text is angry, insulting, all-caps, negative, or contains profanity. Do not wake just because the user says "keep going" unless the message is about the agent failing to continue or finish assigned work.

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
Use needs_context when should_wake=true but the durable layer cannot be chosen from this message alone.

JSON schema:
{
  "should_wake": boolean,
  "wake_label": "...",
  "route_label": "...",
  "confidence": 0.0-1.0,
  "reason": "short reason under 18 words"
}
"""

BALANCED_SYSTEM_PROMPT = """You label user messages for Introspect, a local agent self-improvement system.

Return strict JSON only.

Classify the target of the user's message.

Wake when the target is the agent's behavior, process, or durability:
- The user says the agent did not test, read, search, verify, label, train, continue, use subagents/tools, use the requested machine, or finish the assigned work.
- The user asks why the agent made a bad choice, ignored instructions, lost context, used the wrong layer/tool, stopped early, or needs durable prompt/skill/memory improvement.
- The user pressures the agent to keep going because the current agent run is incomplete or wrong.
- Angry or hostile wording still wakes when it contains a concrete agent-process failure.

Do not wake when the target is the product, app, codebase, external system, or quoted material:
- A normal implementation request: add UI, graphs, charts, diffs, classifiers, model training, search, tests, docs, or product behavior.
- Product/code feedback: the app should show more detail, a classifier should replace hardcoded words, metrics should be better.
- Pasted logs, transcripts, examples, prompts, or quoted hostile text.
- General venting, insults, profanity, all-caps, or negative sentiment without a concrete agent-process failure.

Decision test:
1. Write the implied complaint in plain words.
2. If it is "the agent handled the work badly", set should_wake=true.
3. If it is "the product/code should be different" or "do this next task", set should_wake=false.

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
Use needs_context when should_wake=true but the durable layer cannot be chosen from this message alone.

JSON schema:
{
  "should_wake": boolean,
  "wake_label": "...",
  "route_label": "...",
  "confidence": 0.0-1.0,
  "reason": "short reason under 18 words"
}
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
            if row.get("record_id"):
                ids.add(str(row["record_id"]))
    return ids


def compact_text(text: str, max_chars: int = 1400) -> str:
    text = " ".join(str(text).split())
    return text[:max_chars]


def parse_json(content: str) -> dict[str, Any]:
    content = content.strip()
    if content.startswith("```"):
        content = content.strip("`")
        content = content.removeprefix("json").strip()
    start = content.find("{")
    end = content.rfind("}")
    if start >= 0 and end >= start:
        content = content[start:end + 1]
    return json.loads(content)


def label_record(
    row: dict[str, Any],
    timeout: int,
    retries: int,
    max_chars: int,
    max_tokens: int,
    system_prompt: str,
) -> dict[str, Any]:
    user_payload = {
        "record_id": row["id"],
        "source": row.get("source"),
        "cwd": row.get("cwd"),
        "old_trigger": row.get("old_trigger"),
        "weak_label": row.get("weak_label"),
        "matched_words": row.get("matched_words", []),
        "text": compact_text(row.get("text", ""), max_chars),
    }
    payload = {
        "model": MODEL,
        "temperature": 0,
        "max_tokens": max_tokens,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": json.dumps(user_payload, ensure_ascii=False)},
        ],
    }
    data = json.dumps(payload).encode()
    for attempt in range(retries + 1):
        try:
            request = urllib.request.Request(
                ENDPOINT,
                data=data,
                headers={"Content-Type": "application/json"},
            )
            response = urllib.request.urlopen(request, timeout=timeout)
            body = json.loads(response.read().decode())
            content = body["choices"][0]["message"]["content"]
            label = parse_json(content)
            return {
                "record_id": row["id"],
                "source": row.get("source"),
                "locator": row.get("locator"),
                "old_trigger": row.get("old_trigger"),
                "weak_label": row.get("weak_label"),
                "wake_label": label.get("wake_label"),
                "route_label": label.get("route_label"),
                "should_wake": bool(label.get("should_wake")),
                "confidence": float(label.get("confidence") or 0),
                "reason": str(label.get("reason") or "")[:240],
            }
        except Exception as exc:
            if attempt >= retries:
                return {
                    "record_id": row["id"],
                    "source": row.get("source"),
                    "locator": row.get("locator"),
                    "error": f"{type(exc).__name__}: {str(exc)[:240]}",
                }
            time.sleep(1.5 * (attempt + 1))
    raise AssertionError("unreachable")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--progress-every", type=int, default=25)
    parser.add_argument("--max-chars", type=int, default=900)
    parser.add_argument("--max-tokens", type=int, default=120)
    parser.add_argument("--prompt", choices=["baseline", "strict", "balanced", "fast-balanced"], default="fast-balanced")
    parser.add_argument("--max-in-flight", type=int, default=0)
    args = parser.parse_args()

    rows = read_jsonl(args.input)
    completed_ids = existing_ids(args.output)
    rows = [row for row in rows if row["id"] not in completed_ids]
    if args.limit:
        rows = rows[:args.limit]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    written = 0
    prompt = {
        "baseline": BASELINE_SYSTEM_PROMPT,
        "strict": STRICT_SYSTEM_PROMPT,
        "balanced": BALANCED_SYSTEM_PROMPT,
        "fast-balanced": FAST_BALANCED_SYSTEM_PROMPT,
    }[args.prompt]
    max_in_flight = args.max_in_flight or max(args.workers * 4, args.workers)
    row_iter = iter(rows)
    with args.output.open("a") as out:
        with futures.ThreadPoolExecutor(max_workers=args.workers) as executor:
            future_map: dict[futures.Future[dict[str, Any]], dict[str, Any]] = {}

            def submit_next() -> bool:
                try:
                    row = next(row_iter)
                except StopIteration:
                    return False
                future_map[
                    executor.submit(
                        label_record,
                        row,
                        args.timeout,
                        args.retries,
                        args.max_chars,
                        args.max_tokens,
                        prompt,
                    )
                ] = row
                return True

            while len(future_map) < max_in_flight and submit_next():
                pass

            while future_map:
                finished, _ = futures.wait(future_map, return_when=futures.FIRST_COMPLETED)
                for future in finished:
                    future_map.pop(future, None)
                    result = future.result()
                    submit_next()
                    with lock:
                        out.write(json.dumps(result, ensure_ascii=False) + "\n")
                        out.flush()
                        written += 1
                        if args.progress_every > 0 and written % args.progress_every == 0:
                            print(f"labeled {written}/{len(rows)}", flush=True)
    print(json.dumps({"input": str(args.input), "output": str(args.output), "new_labels": written, "already_done": len(completed_ids)}, sort_keys=True))


if __name__ == "__main__":
    main()
