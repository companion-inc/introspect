#!/usr/bin/env python3
"""Regression tests for the foreground frustration tripwire."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HOOK = REPO / "hooks" / "frustration-reflect.sh"


def read_jsonl(path: Path) -> list[dict]:
    if not path.exists():
        return []
    rows: list[dict] = []
    for line in path.read_text().splitlines():
        if line.strip():
            rows.append(json.loads(line))
    return rows


def run_case(
    prompt: str,
    should_trigger: bool,
    expected_match: str | None = None,
    reflect_mode: str = "immediate",
) -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-tripwire-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "AGENTS_MD_REPO": str(REPO),
                "AGENTS_MD_PROMPT": str(REPO / "AGENTS.md"),
                "AGENTS_MD_SKILLS_DIR": str(REPO / "skills"),
                "AGENTS_MD_FEEDBACK_DIR": str(tmp),
                "FRUSTRATION_REFLECTOR_DRY_RUN": "1",
                "FRUSTRATION_DEBOUNCE_SECONDS": "0",
                "FRUSTRATION_DISABLE_SCHEDULE": "1",
            }
        )
        if reflect_mode:
            env["AGENT_LOOP_REFLECT_MODE"] = reflect_mode
        else:
            env.pop("AGENT_LOOP_REFLECT_MODE", None)
        payload = {
            "prompt": prompt,
            "session_id": "tripwire-test",
            "cwd": str(REPO),
            "transcript_path": "",
        }
        subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(payload),
            text=True,
            env=env,
            cwd=REPO,
            check=True,
            timeout=10,
        )

        events = read_jsonl(tmp / "events.jsonl")
        if len(events) != 1:
            raise AssertionError(f"{prompt!r}: expected exactly one logged event, got {len(events)}")
        event = events[0]
        if bool(event.get("frustrated")) != should_trigger:
            raise AssertionError(f"{prompt!r}: frustrated={event.get('frustrated')} expected {should_trigger}")

        if expected_match and expected_match not in event.get("matched", []):
            raise AssertionError(f"{prompt!r}: missing expected match {expected_match!r} in {event.get('matched')}")

        deadline = time.time() + 5
        batches: list[dict] = []
        while time.time() < deadline:
            batches = read_jsonl(tmp / "reflector-batches.jsonl")
            if batches or not should_trigger:
                break
            time.sleep(0.1)

        if should_trigger:
            if not batches:
                raise AssertionError(f"{prompt!r}: expected a dry-run reflector batch")
            if batches[-1].get("event_count") != 1:
                raise AssertionError(f"{prompt!r}: expected one batched event, got {batches[-1]}")
        elif batches:
            raise AssertionError(f"{prompt!r}: should not have created a reflector batch")


def run_queue_only_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-tripwire-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "AGENTS_MD_REPO": str(REPO),
                "AGENTS_MD_PROMPT": str(REPO / "AGENTS.md"),
                "AGENTS_MD_SKILLS_DIR": str(REPO / "skills"),
                "AGENTS_MD_FEEDBACK_DIR": str(tmp),
                "FRUSTRATION_REFLECTOR_DRY_RUN": "1",
                "FRUSTRATION_DEBOUNCE_SECONDS": "0",
                "FRUSTRATION_DISABLE_SCHEDULE": "1",
            }
        )
        env.pop("AGENT_LOOP_REFLECT_MODE", None)
        subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(
                {
                    "prompt": "what the fuck is going on",
                    "session_id": "tripwire-queue-only-test",
                    "cwd": str(REPO),
                    "transcript_path": "",
                }
            ),
            text=True,
            env=env,
            cwd=REPO,
            check=True,
            timeout=10,
        )
        events = read_jsonl(tmp / "events.jsonl")
        queue = read_jsonl(tmp / "frustration-queue.jsonl")
        batches = read_jsonl(tmp / "reflector-batches.jsonl")
        if len(events) != 1 or not events[0].get("frustrated"):
            raise AssertionError("queue-only case did not log one frustrated event")
        if len(queue) != 1:
            raise AssertionError("queue-only case did not enqueue exactly one event")
        if batches:
            raise AssertionError("queue-only default should not spawn a reflector batch")


def main() -> int:
    cases = [
        ("same with shit locally in companion and stuff", False, None),
        ("holy shit can you open this file", False, None),
        ("this shitshow should not match a prefix", False, None),
        ("you idiots should not trigger a plural match", False, None),
        ("why the hell would it do that", True, "hell"),
        ("what the fuck is going on", True, "fuck"),
        ("this is bullshit", True, "bullshit"),
        ("that behavior is shitty", True, "shitty"),
    ]
    for prompt, should_trigger, expected_match in cases:
        run_case(prompt, should_trigger, expected_match)
    run_queue_only_case()
    print(f"test-frustration-tripwire: ok ({len(cases) + 1} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
