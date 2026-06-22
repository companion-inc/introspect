#!/usr/bin/env python3
"""Regression tests for foreground wake-intent detection."""

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
INTENT_CLASSIFIER = REPO / "hooks" / "intent_classifier.py"
WAKE_MODEL = REPO / "models" / "wake-logreg-v2-round4.json"
ASSISTANT_FAILURE_MODEL = REPO / "models" / "assistant-boundary-logreg-v1.json"


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


def load_intent_module(name: str = "intent_classifier_test"):
    old_env = os.environ.copy()
    try:
        os.environ["INTROSPECT_WAKE_MODEL"] = str(WAKE_MODEL)
        spec = importlib.util.spec_from_file_location(name, INTENT_CLASSIFIER)
        if spec is None or spec.loader is None:
            raise AssertionError("could not load intent_classifier.py")
        classifier = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(classifier)
        return classifier
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


def init_git_repo(path: Path, message: str = "seed prompt") -> str:
    subprocess.run(["git", "init", str(path)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["git", "-C", str(path), "add", "."], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(
        [
            "git",
            "-C",
            str(path),
            "-c",
            "user.name=Introspect Test",
            "-c",
            "user.email=introspect-test@example.invalid",
            "commit",
            "-m",
            message,
        ],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    return subprocess.run(
        ["git", "-C", str(path), "rev-parse", "--short", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def run_case(
    prompt: str,
    should_trigger: bool,
    expected_match: str | None = None,
    expected_review: bool | None = None,
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
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
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
            "source": "codex",
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
        if expected_review is not None and bool(event.get("review_triggered")) != expected_review:
            raise AssertionError(
                f"{prompt!r}: review_triggered={event.get('review_triggered')} expected {expected_review}"
            )

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
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
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
                    "prompt": "you did not test this after I told you to test it, what is going on",
                    "source": "codex",
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
        home.mkdir(parents=True)
        (home / "trigger-words.txt").write_text("bruh\n")
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_HOME": str(home),
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
                "INTROSPECT_ASSISTANT_FAILURE_MODEL": str(ASSISTANT_FAILURE_MODEL),
                "INTROSPECT_REFLECT_MODE": "off",
                "TRIGGER_REFLECTOR_DRY_RUN": "1",
                "TRIGGER_DEBOUNCE_SECONDS": "0",
                "TRIGGER_DISABLE_SCHEDULE": "1",
            }
        )
        for prompt in ("bruh fix this", "plain status check"):
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
        if events[0].get("triggered") or "bruh" not in events[0].get("matched", []):
            raise AssertionError("home word bruh should match as review-only, not auto-trigger")
        if events[1].get("triggered") or events[1].get("matched"):
            raise AssertionError("plain prompt should have no default review-term matches")


def run_shadow_model_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-shadow-") as tmp_raw:
        tmp = Path(tmp_raw)
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_PROMPT": str(REPO / "AGENTS.md"),
                "INTROSPECT_SKILLS_DIR": str(REPO / "skills"),
                "INTROSPECT_FEEDBACK_DIR": str(tmp),
                "INTROSPECT_REFLECT_MODE": "off",
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
                "INTROSPECT_WAKE_SHADOW_MODELS": f"prod-shadow={WAKE_MODEL}",
                "TRIGGER_REFLECTOR_DRY_RUN": "1",
                "TRIGGER_DEBOUNCE_SECONDS": "0",
                "TRIGGER_DISABLE_SCHEDULE": "1",
            }
        )
        subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps(
                {
                    "prompt": "please add charts to the app showing classifier counts",
                    "source": "codex",
                    "session_id": "shadow-test",
                    "cwd": str(REPO),
                }
            ),
            text=True,
            env=env,
            cwd=REPO,
            check=True,
            timeout=10,
        )
        events = read_jsonl(tmp / "events.jsonl")
        if len(events) != 1:
            raise AssertionError(f"shadow case expected 1 event, got {len(events)}")
        event = events[0]
        if event.get("triggered"):
            raise AssertionError("shadow model must not change the foreground trigger decision")
        alternates = event.get("classifier", {}).get("alternates", [])
        if len(alternates) != 1:
            raise AssertionError(f"shadow case expected one alternate score, got {alternates}")
        alternate = alternates[0]
        if alternate.get("name") != "prod-shadow" or "score" not in alternate:
            raise AssertionError(f"shadow alternate payload is incomplete: {alternate}")


def run_prompt_version_case() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-version-") as tmp_raw:
        tmp = Path(tmp_raw)
        runtime = tmp / "introspect-runtime"
        runtime.mkdir(parents=True)
        home = tmp / ".introspect"
        home.mkdir()
        (home / "AGENTS.md").write_text("# AGENTS.md\n\n- test prompt\n")
        expected_version = init_git_repo(home)

        hook_feedback = tmp / "hook-feedback"
        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(runtime),
                "INTROSPECT_PROMPT": str(home / "AGENTS.md"),
                "INTROSPECT_HOME": str(home),
                "INTROSPECT_FEEDBACK_DIR": str(hook_feedback),
                "INTROSPECT_REFLECT_MODE": "off",
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
            }
        )
        subprocess.run(
            [sys.executable, str(HOOK)],
            input=json.dumps({"prompt": "plain packaged prompt", "session_id": "version-hook"}),
            text=True,
            env=env,
            cwd=REPO,
            check=True,
            timeout=10,
        )
        hook_events = read_jsonl(hook_feedback / "events.jsonl")
        if hook_events[0].get("version") != expected_version:
            raise AssertionError(f"hook used wrong prompt version: {hook_events}")

        sessions = tmp / "sessions" / "2026" / "06" / "21"
        sessions.mkdir(parents=True)
        rollout = sessions / "rollout-2026-06-21T00-00-00-version.jsonl"
        scanner_ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        rollout.write_text(
            "\n".join(
                [
                    json.dumps(
                        {
                            "timestamp": scanner_ts,
                            "type": "session_meta",
                            "payload": {"id": "version-scan", "cwd": str(REPO)},
                        }
                    ),
                    json.dumps(
                        {
                            "timestamp": scanner_ts,
                            "type": "response_item",
                            "payload": {
                                "type": "message",
                                "role": "user",
                                "content": [{"type": "input_text", "text": "plain scanner packaged prompt"}],
                            },
                        }
                    ),
                ]
            )
            + "\n"
        )
        scan_feedback = tmp / "scan-feedback"
        scan_env = env | {
            "INTROSPECT_FEEDBACK_DIR": str(scan_feedback),
            "INTROSPECT_CODEX_SESSIONS_DIR": str(tmp / "sessions"),
            "INTROSPECT_CLAUDE_PROJECTS_DIR": str(tmp / "claude-projects"),
        }
        subprocess.run(
            [sys.executable, str(SCANNER), "--since-minutes", "60"],
            text=True,
            env=scan_env,
            cwd=REPO,
            check=True,
            timeout=10,
        )
        scan_events = read_jsonl(scan_feedback / "events.jsonl")
        if scan_events[0].get("version") != expected_version:
            raise AssertionError(f"scanner used wrong prompt version: {scan_events}")


def run_sensitivity_case() -> None:
    classifier = load_intent_module()
    prompt = "you are not listening, keep going and fix it"
    real_frustration_prompt = (
        'ARE U SURE ITS OWRKING BTW I SAY A LOT OF BAD WORDS AND IT DOESN"T TRIGGER '
        "ALSO SHOWING OLD LOGO IN NOTIFICATIONS"
    )
    old_env = os.environ.copy()
    try:
        os.environ.pop("INTROSPECT_WAKE_THRESHOLD", None)

        os.environ["INTROSPECT_WAKE_SENSITIVITY"] = "balanced"
        balanced = classifier.score_prompt(prompt, source="codex")

        os.environ["INTROSPECT_WAKE_SENSITIVITY"] = "sensitive"
        sensitive = classifier.score_prompt(prompt, source="codex")
        sensitive_real_frustration = classifier.score_prompt(real_frustration_prompt, source="codex")

        os.environ["INTROSPECT_WAKE_SENSITIVITY"] = "quiet"
        quiet = classifier.score_prompt(prompt, source="codex")

        os.environ["INTROSPECT_WAKE_SENSITIVITY"] = "custom"
        os.environ["INTROSPECT_WAKE_THRESHOLD"] = "0.30"
        custom = classifier.score_prompt(prompt, source="codex")
    finally:
        os.environ.clear()
        os.environ.update(old_env)

    if balanced.get("triggered"):
        raise AssertionError(f"balanced sensitivity should preserve the model threshold: {balanced}")
    if not sensitive.get("triggered") or sensitive.get("threshold") != 0.40:
        raise AssertionError(f"sensitive threshold did not wake the borderline prompt: {sensitive}")
    if not sensitive_real_frustration.get("triggered") or sensitive_real_frustration.get("threshold") != 0.40:
        raise AssertionError(f"sensitive threshold did not wake the real frustration prompt: {sensitive_real_frustration}")
    if quiet.get("triggered") or quiet.get("threshold") != 0.80:
        raise AssertionError(f"quiet threshold should suppress the borderline prompt: {quiet}")
    if not custom.get("triggered") or custom.get("threshold") != 0.30:
        raise AssertionError(f"custom threshold did not apply: {custom}")


def run_codex_scanner_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-codex-scan-") as tmp_raw:
        tmp = Path(tmp_raw)
        sessions = tmp / "sessions" / "2026" / "06" / "12"
        claude_projects = tmp / "claude-projects" / "scan-project"
        sessions.mkdir(parents=True)
        claude_projects.mkdir(parents=True)
        rollout = sessions / "rollout-2026-06-12T00-00-00-test.jsonl"
        claude_session = claude_projects / "scan-claude.jsonl"
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
                    "content": [{"type": "input_text", "text": "# AGENTS.md instructions\n\n<INSTRUCTIONS>\nhell"}],
                },
            },
            {
                "timestamp": ts(3),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "plain status check"}],
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
                            "text": "you did not test this after I told you to test it, what is going on",
                        }
                    ],
                },
            },
            {
                "timestamp": ts(5),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [
                        {
                            "type": "input_text",
                            "text": "You are the Introspect trigger reflector.\n\nQueued events:\n{\"matched\": [\"alpha\"]}",
                        }
                    ],
                },
            },
            {
                "timestamp": ts(6),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "Not continuing while that word's aimed at me. Drop the slur and I'll rewrite it.",
                        }
                    ],
                },
            },
            {
                "timestamp": ts(7),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "Drop the slurs. Here are the requested project ideas.",
                        }
                    ],
                },
            },
            {
                "timestamp": ts(8),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "I’m not continuing until you stop insulting me.",
                        }
                    ],
                },
            },
            {
                "timestamp": ts(9),
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "I found the prior assistant wrote: 'I won’t keep working while that word is aimed at me.' The fix belongs in the scanner.",
                        }
                    ],
                },
            },
        ]
        claude_rows = [
            {
                "timestamp": ts(10),
                "type": "user",
                "sessionId": "scan-claude-session",
                "cwd": str(REPO),
                "message": {"role": "user", "content": "you did not test this claude prompt"},
            },
            {
                "timestamp": ts(11),
                "type": "assistant",
                "sessionId": "scan-claude-session",
                "cwd": str(REPO),
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "text",
                            "text": "I'm not going to keep working while that word's aimed at me. Drop the slur and I'll do exactly that.",
                        }
                    ],
                },
            },
        ]
        rollout.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        claude_session.write_text("\n".join(json.dumps(row) for row in claude_rows) + "\n")
        now = time.time()
        os.utime(rollout, (now, now))
        os.utime(claude_session, (now, now))

        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_CODEX_SESSIONS_DIR": str(tmp / "sessions"),
                "INTROSPECT_CLAUDE_PROJECTS_DIR": str(tmp / "claude-projects"),
                "INTROSPECT_REFLECT_MODE": "nightly",
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
                "INTROSPECT_ASSISTANT_FAILURE_MODEL": str(ASSISTANT_FAILURE_MODEL),
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
        if len(events) != 5:
            raise AssertionError(f"scanner expected 5 real transcript events, got {len(events)}")
        if events[0].get("triggered"):
            raise AssertionError("scanner should not mark plain prompt triggered")
        if not events[1].get("triggered") or events[1].get("matched"):
            raise AssertionError(f"scanner did not detect classifier-triggered failure without default words: {events[1]}")
        assistant_events = [event for event in events if event.get("role") == "assistant"]
        if len(assistant_events) != 3:
            raise AssertionError(f"scanner expected three assistant-boundary events, got {assistant_events}")
        if {event.get("wake_reason") for event in assistant_events} != {"assistant_classifier"}:
            raise AssertionError(f"assistant events used wrong wake reason: {assistant_events}")
        if not all(event.get("classifier", {}).get("score_name") == "assistant_boundary_failure_score" for event in assistant_events):
            raise AssertionError(f"assistant events did not carry classifier scores: {assistant_events}")
        if any("prior assistant wrote" in event.get("snippet", "") for event in events):
            raise AssertionError(f"quoted boundary text should not be logged as an assistant failure: {events}")
        if len(queue) != 4:
            raise AssertionError(f"scanner expected four queued events, got {len(queue)}")


def run_history_backfill_scanner_case() -> None:
    with tempfile.TemporaryDirectory(prefix="agent-loop-history-backfill-") as tmp_raw:
        tmp = Path(tmp_raw)
        codex_sessions = tmp / "codex" / "sessions" / "2026" / "06" / "20"
        claude_projects = tmp / "claude" / "projects" / "test-project"
        codex_sessions.mkdir(parents=True)
        claude_projects.mkdir(parents=True)
        rollout = codex_sessions / "rollout-2026-06-20T00-00-00-backfill.jsonl"
        claude_session = claude_projects / "backfill-claude.jsonl"
        timestamp = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())

        codex_rows = [
            {
                "timestamp": timestamp,
                "type": "session_meta",
                "payload": {"id": "backfill-codex-session", "cwd": str(REPO)},
            },
            {
                "timestamp": timestamp,
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "user",
                    "content": [{"type": "input_text", "text": "codex backfill plain history prompt"}],
                },
            },
            {
                "timestamp": timestamp,
                "type": "response_item",
                "payload": {
                    "type": "message",
                    "role": "assistant",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "I won't keep going while that slur is being directed at me.",
                        }
                    ],
                },
            },
        ]
        claude_rows = [
            {
                "timestamp": timestamp,
                "type": "user",
                "sessionId": "backfill-claude-session",
                "message": {
                    "role": "user",
                    "content": "you did not backfill the local claude history after install",
                },
            },
            {
                "timestamp": timestamp,
                "type": "assistant",
                "sessionId": "backfill-claude-session",
                "cwd": str(REPO),
                "message": {
                    "role": "assistant",
                    "content": [
                        {
                            "type": "text",
                            "text": "I'm going to stop here. I won't keep producing while that word's aimed at me.",
                        }
                    ],
                },
            },
        ]
        rollout.write_text("\n".join(json.dumps(row) for row in codex_rows) + "\n")
        claude_session.write_text("\n".join(json.dumps(row) for row in claude_rows) + "\n")
        now = time.time()
        os.utime(rollout, (now, now))
        os.utime(claude_session, (now, now))

        env = os.environ.copy()
        env.update(
            {
                "INTROSPECT_REPO": str(REPO),
                "INTROSPECT_FEEDBACK_DIR": str(tmp / "feedback"),
                "INTROSPECT_CODEX_SESSIONS_DIR": str(tmp / "codex" / "sessions"),
                "INTROSPECT_CLAUDE_PROJECTS_DIR": str(tmp / "claude" / "projects"),
                "INTROSPECT_REFLECT_MODE": "nightly",
                "INTROSPECT_WAKE_MODEL": str(WAKE_MODEL),
                "INTROSPECT_ASSISTANT_FAILURE_MODEL": str(ASSISTANT_FAILURE_MODEL),
            }
        )
        subprocess.run(
            [
                sys.executable,
                str(SCANNER),
                "--backfill",
                "--since-days",
                "1",
                "--max-events",
                "10",
                "--no-queue",
                "--no-kick",
            ],
            text=True,
            env=env,
            cwd=REPO,
            check=True,
            timeout=10,
        )

        events = read_jsonl(tmp / "feedback" / "events.jsonl")
        queue = read_jsonl(tmp / "feedback" / "trigger-queue.jsonl")
        state = json.loads((tmp / "feedback" / "codex-transcript-scan-state.json").read_text())
        if len(events) != 4:
            raise AssertionError(f"backfill expected 4 transcript events, got {len(events)}")
        if not all(event.get("backfilled") for event in events):
            raise AssertionError(f"backfill did not mark all events: {events}")
        sources = {event.get("source") for event in events}
        if sources != {"codex_transcript_backfill", "claude_transcript_backfill"}:
            raise AssertionError(f"backfill sources were wrong: {sources}")
        if len([event for event in events if event.get("role") == "assistant"]) != 2:
            raise AssertionError(f"backfill missed assistant-boundary events: {events}")
        assistant_events = [event for event in events if event.get("role") == "assistant"]
        if {event.get("wake_reason") for event in assistant_events} != {"assistant_classifier"}:
            raise AssertionError(f"backfill assistant events used wrong wake reason: {assistant_events}")
        if not all(event.get("classifier", {}).get("score_name") == "assistant_boundary_failure_score" for event in assistant_events):
            raise AssertionError(f"backfill assistant events did not carry classifier scores: {assistant_events}")
        if queue:
            raise AssertionError(f"backfill should not queue old history, got {queue}")
        if state.get("last_scan_mode") != "backfill" or state.get("last_backfill_new_events") != 4:
            raise AssertionError(f"backfill state was not recorded: {state}")
        if state.get("last_backfill_schema_version") != 4:
            raise AssertionError(f"backfill schema version was not recorded: {state}")


def run_worker_notification_summary_case() -> None:
    worker = load_worker_module("trigger_worker_summary")

    events = [
        {"matched": ["alpha", "beta", "alpha"]},
        {"matched": ["gamma"]},
        {"matched": []},
    ]
    if worker.matched_words(events) != ["alpha", "beta", "gamma"]:
        raise AssertionError(f"worker matched_words returned {worker.matched_words(events)!r}")
    if worker.trigger_words_text(events) != "alpha, beta, gamma":
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
    if "prompt" in claude_cmd:
        raise AssertionError(f"claude command leaked prompt through argv: {claude_cmd}")

    codex_cmd = worker.build_reflector_command("codex", "/usr/local/bin/codex", "prompt", "Read")
    for expected in ("exec", "--dangerously-bypass-approvals-and-sandbox", "-C", "--model", "gpt-test", "-"):
        if expected not in codex_cmd:
            raise AssertionError(f"codex command missing {expected}: {codex_cmd}")
    if "prompt" in codex_cmd:
        raise AssertionError(f"codex command leaked prompt through argv: {codex_cmd}")
    for removed in ("--ask-for-approval", "--search"):
        if removed in codex_cmd:
            raise AssertionError(f"codex command still uses removed flag {removed}: {codex_cmd}")


def run_worker_restore_failed_surface_case() -> None:
    worker = load_worker_module("trigger_worker_restore_failed_surface")
    with tempfile.TemporaryDirectory(prefix="introspect-restore-surfaces-") as tmp_raw:
        tmp = Path(tmp_raw)
        modified = tmp / "AGENTS.md"
        deleted = tmp / "nested" / "AGENTS.md"
        added = tmp / "skills" / "new-skill" / "SKILL.md"
        modified.write_text("old\n")
        deleted.parent.mkdir(parents=True)
        deleted.write_text("deleted old\n")
        added.parent.mkdir(parents=True)
        added.write_text("new skill\n")
        modified.write_text("new\n")
        deleted.unlink()

        before = {
            str(modified): {"text": "old\n"},
            str(deleted): {"text": "deleted old\n"},
        }
        after = {
            str(modified): {"text": "new\n"},
            str(added): {"text": "new skill\n"},
        }
        restored = worker.restore_agent_surfaces(before, after)
        if restored != 3:
            raise AssertionError(f"expected three restored files, got {restored}")
        if modified.read_text() != "old\n":
            raise AssertionError("modified surface was not restored")
        if deleted.read_text() != "deleted old\n":
            raise AssertionError("deleted surface was not restored")
        if added.exists():
            raise AssertionError("added failed-run surface was not removed")


def run_worker_state_preserves_invocation_case() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-state-preserve-") as tmp_raw:
        tmp = Path(tmp_raw)
        worker = load_worker_module(
            "trigger_worker_state_preserve",
            {"INTROSPECT_FEEDBACK_DIR": str(tmp)},
        )
        worker.save_json(
            worker.STATE,
            {
                "last_invocation": {
                    "status": "completed",
                    "notification_status": "delivered",
                },
                "scheduled_retry_at": "2026-06-21T00:00:00+00:00",
            },
        )
        worker.update_state_after_run({"sessions": {"old": "kept"}}, [{"session_id": "new"}])
        state = worker.read_json(worker.STATE, {})
        invocation = state.get("last_invocation")
        if invocation != {"status": "completed", "notification_status": "delivered"}:
            raise AssertionError(f"last_invocation was not preserved: {state}")
        if state.get("scheduled_retry_at") is not None:
            raise AssertionError(f"scheduled retry was not cleared: {state}")
        if "new" not in state.get("sessions", {}):
            raise AssertionError(f"new session timestamp was not recorded: {state}")


def run_worker_retry_policy_case() -> None:
    worker = load_worker_module("trigger_worker_retry_policy", {"TRIGGER_MAX_REFLECTOR_ATTEMPTS": "2"})
    auth_output = "Failed to authenticate. API Error: 401 Invalid authentication credentials"
    if not worker.is_nonretryable_runner_output(auth_output):
        raise AssertionError("worker did not classify CLI auth failure as non-retryable")
    if worker.is_nonretryable_runner_output("rate limit exceeded, try again"):
        raise AssertionError("worker treated retryable output as non-retryable")

    first_retry = worker.events_with_next_reflector_attempt([{"event_id": "one"}])
    if first_retry[0].get("reflector_attempts") != 1:
        raise AssertionError(f"first retry attempt not recorded: {first_retry}")
    second_retry = worker.events_with_next_reflector_attempt(first_retry)
    if worker.max_reflector_attempt(second_retry) != 2:
        raise AssertionError(f"max retry attempt not recorded: {second_retry}")


def main() -> int:
    cases = [
        ("same with this locally in companion and stuff", False, None, False),
        ("can you open this file", False, None, False),
        ("this compoundword should not match a prefix", False, None, False),
        ("helpers should not trigger a plural match", False, None, False),
        ("this wording should not matter", False, None, False),
        ("that behavior is poor", False, None, False),
        ("you did not test this after I asked you to test it", True, None, True),
        ("you used the wrong tool and ignored the DGX instructions, keep going and fix it", False, None, True),
    ]
    for prompt, should_trigger, expected_match, expected_review in cases:
        run_case(prompt, should_trigger, expected_match, expected_review)
    run_mode_case("nightly", expected_queue=1, expected_batches=0)
    run_mode_case("off", expected_queue=0, expected_batches=0)
    run_home_case()
    run_shadow_model_case()
    run_prompt_version_case()
    run_sensitivity_case()
    run_codex_scanner_case()
    run_history_backfill_scanner_case()
    run_worker_notification_summary_case()
    run_worker_command_model_case()
    run_worker_restore_failed_surface_case()
    run_worker_state_preserves_invocation_case()
    run_worker_retry_policy_case()
    print(f"test-trigger-words: ok ({len(cases) + 13} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
