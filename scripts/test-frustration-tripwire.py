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
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp),
                "FRUSTRATION_REFLECTOR_DRY_RUN": "1",
                "FRUSTRATION_DEBOUNCE_SECONDS": "0",
                "FRUSTRATION_DISABLE_SCHEDULE": "1",
            }
        )
        if reflect_mode:
            env["INTROSPECT_REFLECT_MODE"] = reflect_mode
        else:
            env.pop("INTROSPECT_REFLECT_MODE", None)
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


def run_mode_case(reflect_mode: str, expected_queue: int, expected_batches: int) -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-tripwire-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp),
                "FRUSTRATION_REFLECTOR_DRY_RUN": "1",
                "FRUSTRATION_DEBOUNCE_SECONDS": "0",
                "FRUSTRATION_DISABLE_SCHEDULE": "1",
            }
        )
        env["INTROSPECT_REFLECT_MODE"] = reflect_mode
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
        if len(queue) != expected_queue:
            raise AssertionError(f"{reflect_mode}: expected {expected_queue} queued event(s), got {len(queue)}")
        if len(batches) != expected_batches:
            raise AssertionError(f"{reflect_mode}: expected {expected_batches} batch(es), got {len(batches)}")


def run_profile_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-profile-") as tmp_raw:
        tmp = Path(tmp_raw)
        profile = tmp / "profile"
        profile.mkdir()
        (profile / "frustration-words.json").write_text(
            json.dumps({"include": ["bruh"], "exclude": ["hell"]})
        )
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_PROFILE_DIR": str(profile),
                "INTROSPECT_REFLECT_MODE": "off",
                "FRUSTRATION_REFLECTOR_DRY_RUN": "1",
                "FRUSTRATION_DEBOUNCE_SECONDS": "0",
                "FRUSTRATION_DISABLE_SCHEDULE": "1",
            }
        )
        for prompt in ("bruh fix this", "why the hell"):
            subprocess.run(
                [sys.executable, str(HOOK)],
                input=json.dumps({"prompt": prompt, "session_id": "profile-test", "cwd": str(REPO)}),
                text=True,
                env=env,
                cwd=REPO,
                check=True,
                timeout=10,
            )
        events = read_jsonl(tmp / "feedback" / "events.jsonl")
        if len(events) != 2:
            raise AssertionError(f"profile case expected 2 events, got {len(events)}")
        if not events[0].get("frustrated") or "bruh" not in events[0].get("matched", []):
            raise AssertionError("profile include did not trigger bruh")
        if events[1].get("frustrated"):
            raise AssertionError("profile exclude did not suppress hell")


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
    run_mode_case("nightly", expected_queue=1, expected_batches=0)
    run_mode_case("off", expected_queue=0, expected_batches=0)
    run_profile_case()
    print(f"test-frustration-tripwire: ok ({len(cases) + 3} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
