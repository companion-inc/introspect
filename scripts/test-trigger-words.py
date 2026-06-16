#!/usr/bin/env python3
"""Regression tests for foreground trigger-word detection."""

from __future__ import annotations

import json
import importlib.util
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HOOK = REPO / "hooks" / "trigger-reflect.sh"
SCANNER = REPO / "hooks" / "codex-transcript-scan.py"
WORKER = REPO / "hooks" / "trigger-worker.py"


def load_worker_module(name: str, env_updates: dict[str, str] | None = None):
    old_env = os.environ.copy()
    try:
        if env_updates:
            os.environ.update(env_updates)
        spec = importlib.util.spec_from_file_location(name, WORKER)
        if spec is None or spec.loader is None:
            raise AssertionError("could not load trigger-worker.py")
        worker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(worker)
        return worker
    finally:
        os.environ.clear()
        os.environ.update(old_env)


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
    with tempfile.TemporaryDirectory(prefix="agent-loop-trigger-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp),
                "TRIGGER_REFLECTOR_DRY_RUN": "1",
                "TRIGGER_DEBOUNCE_SECONDS": "0",
                "TRIGGER_DISABLE_SCHEDULE": "1",
            }
        )
        if reflect_mode:
            env["INTROSPECT_REFLECT_MODE"] = reflect_mode
        else:
            env.pop("INTROSPECT_REFLECT_MODE", None)
        payload = {
            "prompt": prompt,
            "session_id": "trigger-test",
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
        if bool(event.get("triggered")) != should_trigger:
            raise AssertionError(f"{prompt!r}: triggered={event.get('triggered')} expected {should_trigger}")

        if expected_match and expected_match not in event.get("matched", []):
            raise AssertionError(f"{prompt!r}: missing expected match {expected_match!r} in {event.get('matched')}")

        deadline = time.time() + 10
        batches: list[dict] = []
        batch: dict | None = None
        prompt_path = Path("")
        surface_diff_path = Path("")
        while time.time() < deadline:
            batches = read_jsonl(tmp / "reflector-batches.jsonl")
            if not should_trigger:
                break
            if batches:
                batch = batches[-1]
                prompt_path_raw = batch.get("prompt_path", "")
                surface_diff_path_raw = batch.get("surface_diff_path", "")
                prompt_path = Path(prompt_path_raw)
                surface_diff_path = Path(surface_diff_path_raw)
                if prompt_path_raw and surface_diff_path_raw and prompt_path.is_file() and surface_diff_path.is_file():
                    break
            time.sleep(0.1)

        if should_trigger:
            if not batch:
                raise AssertionError(f"{prompt!r}: expected a dry-run reflector batch")
            if batch.get("event_count") != 1:
                raise AssertionError(f"{prompt!r}: expected one batched event, got {batch}")
            if not prompt_path.is_file():
                raise AssertionError(f"{prompt!r}: missing persisted reflector prompt {prompt_path}")
            if not surface_diff_path.is_file():
                raise AssertionError(f"{prompt!r}: missing persisted surface diff {surface_diff_path}")
            diff_payload = json.loads(surface_diff_path.read_text())
            if diff_payload.get("changed_count") != 0:
                raise AssertionError(f"{prompt!r}: dry run should record zero surface changes")
        elif batches:
            raise AssertionError(f"{prompt!r}: should not have created a reflector batch")


def run_mode_case(reflect_mode: str, expected_queue: int, expected_batches: int) -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-trigger-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp),
                "TRIGGER_REFLECTOR_DRY_RUN": "1",
                "TRIGGER_DEBOUNCE_SECONDS": "0",
                "TRIGGER_DISABLE_SCHEDULE": "1",
            }
        )
        env["INTROSPECT_REFLECT_MODE"] = reflect_mode
        subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(
                {
                    "prompt": "what the fuck is going on",
                    "session_id": "trigger-queue-only-test",
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
        queue = read_jsonl(tmp / "trigger-queue.jsonl")
        batches = read_jsonl(tmp / "reflector-batches.jsonl")
        if len(events) != 1 or not events[0].get("triggered"):
            raise AssertionError("queue-only case did not log one triggered event")
        if len(queue) != expected_queue:
            raise AssertionError(f"{reflect_mode}: expected {expected_queue} queued event(s), got {len(queue)}")
        if len(batches) != expected_batches:
            raise AssertionError(f"{reflect_mode}: expected {expected_batches} batch(es), got {len(batches)}")


def run_home_case() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-home-") as tmp_raw:
        tmp = Path(tmp_raw)
        home = tmp / ".introspect"
        home.mkdir()
        (home / "trigger-words.txt").write_text("bruh\n")
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_HOME": str(home),
                "INTROSPECT_REFLECT_MODE": "off",
                "TRIGGER_REFLECTOR_DRY_RUN": "1",
                "TRIGGER_DEBOUNCE_SECONDS": "0",
                "TRIGGER_DISABLE_SCHEDULE": "1",
            }
        )
        for prompt in ("bruh fix this", "why the hell"):
            subprocess.run(
                [sys.executable, str(HOOK)],
                input=json.dumps({"prompt": prompt, "session_id": "home-test", "cwd": str(REPO)}),
                text=True,
                env=env,
                cwd=REPO,
                check=True,
                timeout=10,
            )
        events = read_jsonl(tmp / "feedback" / "events.jsonl")
        if len(events) != 2:
            raise AssertionError(f"home case expected 2 events, got {len(events)}")
        if not events[0].get("triggered") or "bruh" not in events[0].get("matched", []):
            raise AssertionError("home words did not trigger bruh")
        if events[1].get("triggered"):
            raise AssertionError("home words should replace defaults")


def run_codex_scanner_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-codex-scan-") as tmp_raw:
        tmp = Path(tmp_raw)
        sessions = tmp / "sessions" / "2026" / "06" / "12"
        sessions.mkdir(parents=True)
        rollout = sessions / "rollout-2026-06-12T00-00-00-test.jsonl"
        base_ts = time.time()

        def ts(offset: int) -> str:
            return time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(base_ts + offset))

        rows = [
            {
                "timestamp": ts(0),
                "type": "session_meta",
                "payload": {"id": "scan-test-session", "cwd": str(REPO)},
            },
            {
                "timestamp": ts(1),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "# AGENTS.md instructions for /tmp\n\nhell"}],
                },
            },
            {
                "timestamp": ts(2),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "plain status check"}],
                },
            },
            {
                "timestamp": ts(3),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "what the hell is happening"}],
                },
            },
            {
                "timestamp": ts(4),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": "You are the Introspect trigger reflector.\n\nQueued events:\n{\"matched\": [\"fuck\"]}",
                        }
                    ],
                },
            },
        ]
        rollout.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        now = time.time()
        os.utime(rollout, (now, now))

        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_CODEX_SESSIONS_DIR": str(tmp / "sessions"),
                "INTROSPECT_REFLECT_MODE": "nightly",
            }
        )
        for _ in range(2):
            subprocess.run(
                [sys.executable, str(SCANNER), "--since-minutes", "60"],
                text=True,
                env=env,
                cwd=REPO,
                check=True,
                timeout=10,
            )

        events = read_jsonl(tmp / "feedback" / "events.jsonl")
        queue = read_jsonl(tmp / "feedback" / "trigger-queue.jsonl")
        if len(events) != 2:
            raise AssertionError(f"scanner expected 2 real prompt events, got {len(events)}")
        if events[0].get("triggered"):
            raise AssertionError("scanner should not mark plain prompt triggered")
        if not events[1].get("triggered") or "hell" not in events[1].get("matched", []):
            raise AssertionError(f"scanner did not detect exact trigger word: {events[1]}")
        if len(queue) != 1:
            raise AssertionError(f"scanner expected one queued event, got {len(queue)}")


def run_worker_notification_summary_case() -> None:
    worker = load_worker_module("trigger_worker_summary")

    events = [
        {"matched": ["fuck", "retard", "fuck"]},
        {"matched": ["hell"]},
        {"matched": []},
    ]
    if worker.matched_words(events) != ["fuck", "hell", "retard"]:
        raise AssertionError(f"worker matched_words returned {worker.matched_words(events)!r}")
    if worker.trigger_words_text(events) != "fuck, hell, retard":
        raise AssertionError(f"worker trigger_words_text returned {worker.trigger_words_text(events)!r}")


def run_worker_command_model_case() -> None:
    worker = load_worker_module(
        "trigger_worker_models",
        {
            "INTROSPECT_REFLECTOR_CLAUDE_MODEL": "sonnet-test",
            "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL": "haiku-test",
            "INTROSPECT_REFLECTOR_CODEX_MODEL": "gpt-test",
        },
    )
    claude_cmd = worker.build_reflector_command("claude", "/usr/local/bin/claude", "prompt", "Read")
    if "--model" not in claude_cmd or "sonnet-test" not in claude_cmd:
        raise AssertionError(f"claude command missing model override: {claude_cmd}")
    if "--fallback-model" not in claude_cmd or "haiku-test" not in claude_cmd:
        raise AssertionError(f"claude command missing fallback override: {claude_cmd}")

    codex_cmd = worker.build_reflector_command("codex", "/usr/local/bin/codex", "prompt", "Read")
    for expected in ("exec", "--dangerously-bypass-approvals-and-sandbox", "-C", "--model", "gpt-test"):
        if expected not in codex_cmd:
            raise AssertionError(f"codex command missing {expected}: {codex_cmd}")
    for removed in ("--ask-for-approval", "--search"):
        if removed in codex_cmd:
            raise AssertionError(f"codex command still uses removed flag {removed}: {codex_cmd}")


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
    run_home_case()
    run_codex_scanner_case()
    run_worker_notification_summary_case()
    run_worker_command_model_case()
    print(f"test-trigger-words: ok ({len(cases) + 6} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
