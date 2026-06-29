#!/usr/bin/python3
"""Unit checks for Introspect telemetry payload shaping."""

from __future__ import annotations

import importlib.util
import json
import os
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
TELEMETRY_PATH = REPO / "hooks" / "telemetry.py"


def load_module(home: Path):
    os.environ["INTROSPECT_HOME"] = str(home)
    os.environ["INTROSPECT_TELEMETRY_NO_BACKGROUND"] = "1"
    spec = importlib.util.spec_from_file_location("introspect_telemetry_test", TELEMETRY_PATH)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load telemetry module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_settings(home: Path, **overrides):
    payload = {
        "telemetry_enabled": True,
        "telemetry_mode": "basic",
        "telemetry_host": "https://us.i.posthog.com",
        "telemetry_project_token": "",
    }
    payload.update(overrides)
    home.mkdir(parents=True, exist_ok=True)
    (home / "settings.json").write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def sample_event() -> dict:
    return {
        "event_id": "evt-1",
        "ts": "2026-06-28T12:00:00+00:00",
        "observed_at": "2026-06-28T12:00:01+00:00",
        "source": "codex_transcript_scan",
        "role": "user",
        "version": "abc123",
        "triggered": True,
        "review_triggered": True,
        "wake_reason": "classifier",
        "session_id": "session-secret",
        "cwd": "/Users/example/private/project",
        "transcript_path": "/Users/example/.codex/sessions/secret.jsonl",
        "message_locator": "/Users/example/.codex/sessions/secret.jsonl:42",
        "prompt_hash": "prompt-hash",
        "snippet": "email me at person@example.com with sk-test_secret and https://secret.example/path",
        "matched": ["fix", "wrong"],
        "classifier": {
            "score": 0.91,
            "threshold": 0.64,
            "review": True,
            "triggered": True,
            "wake_sensitivity": "balanced",
        },
    }


def read_queue(home: Path) -> list[dict]:
    path = home / "telemetry" / "queue.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def run_disabled_and_unconfigured_cases() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-telemetry-") as raw:
        home = Path(raw)
        write_settings(home, telemetry_enabled=False, telemetry_project_token="phc_test")
        telemetry = load_module(home)
        telemetry.capture_feedback_event(sample_event())
        if read_queue(home):
            raise AssertionError("disabled telemetry queued an event")

    with tempfile.TemporaryDirectory(prefix="introspect-telemetry-") as raw:
        home = Path(raw)
        write_settings(home, telemetry_enabled=True, telemetry_project_token="")
        telemetry = load_module(home)
        telemetry.capture_feedback_event(sample_event())
        if read_queue(home):
            raise AssertionError("missing project token queued an event")


def run_basic_payload_case() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-telemetry-") as raw:
        home = Path(raw)
        write_settings(home, telemetry_enabled=True, telemetry_project_token="phc_test")
        telemetry = load_module(home)
        telemetry.capture_feedback_event(sample_event())
        rows = read_queue(home)
        if len(rows) != 1:
            raise AssertionError(f"expected one telemetry row, got {rows}")
        capture = rows[0]
        props = capture.get("properties", {})
        if capture.get("event") != "introspect.feedback_event":
            raise AssertionError(f"wrong event name: {capture}")
        if not str(capture.get("distinct_id", "")).startswith("introspect:"):
            raise AssertionError(f"wrong distinct id: {capture}")
        for forbidden in ("person@example.com", "sk-test_secret", "secret.example", "/Users/example"):
            if forbidden in json.dumps(capture):
                raise AssertionError(f"basic telemetry leaked {forbidden}: {capture}")
        required = ["snippet_sha256", "snippet_length", "cwd_hash", "session_hash", "classifier_score"]
        missing = [key for key in required if key not in props]
        if missing:
            raise AssertionError(f"missing telemetry props {missing}: {props}")
        if "snippet_redacted" in props:
            raise AssertionError(f"basic telemetry should not include redacted snippet text: {props}")


def run_redacted_payload_case() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-telemetry-") as raw:
        home = Path(raw)
        write_settings(home, telemetry_enabled=True, telemetry_mode="redacted", telemetry_project_token="phc_test")
        telemetry = load_module(home)
        telemetry.capture_feedback_event(sample_event())
        props = read_queue(home)[0]["properties"]
        snippet = props.get("snippet_redacted", "")
        if not snippet:
            raise AssertionError(f"redacted mode omitted snippet: {props}")
        for forbidden in ("person@example.com", "sk-test_secret", "secret.example", "/Users/example"):
            if forbidden in snippet:
                raise AssertionError(f"redacted snippet leaked {forbidden}: {snippet}")


def main() -> int:
    for key in list(os.environ):
        if key.startswith("INTROSPECT_POSTHOG"):
            os.environ.pop(key, None)
    run_disabled_and_unconfigured_cases()
    run_basic_payload_case()
    run_redacted_payload_case()
    print("test-telemetry: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
