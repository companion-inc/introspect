#!/usr/bin/env python3
"""Backstop scanner for Codex Desktop session transcripts.

Codex command hooks can be skipped when a changed hook has not been trusted yet
or when an already-open app session has not reloaded hook config. This scanner
uses Codex's own JSONL session files as the second signal path, then feeds the
same trigger queue handled by trigger-worker.py.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from intent_classifier import score_prompt
except Exception:
    score_prompt = None

REPO = Path(os.path.expanduser(os.environ.get("INTROSPECT_REPO", "~/Companion/Code/introspect")))
FEEDBACK_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_FEEDBACK_DIR", str(REPO / "feedback")))
)
EVENTS = FEEDBACK_DIR / "events.jsonl"
QUEUE = FEEDBACK_DIR / "trigger-queue.jsonl"
STATE = FEEDBACK_DIR / "codex-transcript-scan-state.json"
WORKER = REPO / "hooks" / "trigger-worker.py"
HOOK = REPO / "hooks" / "trigger-reflect.sh"
INTROSPECT_HOME = Path(os.path.expanduser(os.environ.get("INTROSPECT_HOME") or "~/.introspect"))
TRIGGER_WORDS_FILE = INTROSPECT_HOME / "trigger-words.txt"
CODEX_SESSIONS_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_CODEX_SESSIONS_DIR", "~/.codex/sessions"))
)
REFLECT_MODE = (os.environ.get("INTROSPECT_REFLECT_MODE") or "immediate").strip().lower()
DEFAULT_SCAN_MINUTES = int(os.environ.get("INTROSPECT_CODEX_SCAN_MINUTES", "15"))
MAX_STATE_KEYS = int(os.environ.get("INTROSPECT_CODEX_SCAN_STATE_KEYS", "5000"))


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="seconds")


def parse_ts(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def append_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def normalize_words(values: object) -> set[str]:
    if not isinstance(values, list):
        return set()
    words: set[str] = set()
    for value in values:
        if isinstance(value, str):
            normalized = value.strip().lower()
            if re.fullmatch(r"[a-z]+", normalized):
                words.add(normalized)
    return words


def active_trigger_words() -> set[str]:
    try:
        return normalize_words(TRIGGER_WORDS_FILE.read_text().splitlines())
    except Exception:
        return set()


def git_version() -> str:
    try:
        return (
            subprocess.run(
                ["git", "-C", str(REPO), "rev-parse", "--short", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout.strip()
            or "unknown"
        )
    except Exception:
        return "unknown"


def prompt_text_from_content(content: object) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict):
            text = item.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(part for part in parts if part)


def is_codex_control_message(prompt: str) -> bool:
    stripped = prompt.lstrip()
    return (
        stripped.startswith("# AGENTS.md instructions for ")
        or stripped.startswith("<codex_internal_context ")
        or stripped.startswith("<turn_aborted>")
        or stripped.startswith("You are the Introspect trigger reflector.")
    )


def event_key(path: Path, line_no: int, timestamp: str, text: str) -> str:
    digest = hashlib.sha256()
    digest.update(str(path).encode())
    digest.update(b"\0")
    digest.update(str(line_no).encode())
    digest.update(b"\0")
    digest.update(timestamp.encode())
    digest.update(b"\0")
    digest.update(text.encode())
    return digest.hexdigest()


def candidate_files(since_minutes: int) -> list[Path]:
    if not CODEX_SESSIONS_DIR.exists():
        return []
    cutoff = time.time() - max(since_minutes, 1) * 60
    files: list[Path] = []
    for path in CODEX_SESSIONS_DIR.rglob("rollout-*.jsonl"):
        try:
            if path.stat().st_mtime >= cutoff:
                files.append(path)
        except OSError:
            continue
    return sorted(files, key=lambda item: item.stat().st_mtime)


def session_metadata(path: Path) -> tuple[str, str]:
    session_id = ""
    cwd = ""
    try:
        with path.open(errors="ignore") as f:
            for raw in f:
                try:
                    row = json.loads(raw)
                except Exception:
                    continue
                if row.get("type") != "session_meta":
                    continue
                payload = row.get("payload")
                if not isinstance(payload, dict):
                    continue
                session_id = str(payload.get("id") or session_id)
                cwd = str(payload.get("cwd") or cwd)
                break
    except OSError:
        pass
    return session_id, cwd


def scan_file(
    path: Path,
    processed: dict[str, str],
    words: set[str],
    version: str,
    cutoff_ts: dt.datetime,
    *,
    write_events: bool,
) -> tuple[int, int, list[dict]]:
    session_id, cwd = session_metadata(path)
    new_events = 0
    triggered_events = 0
    queued: list[dict] = []

    try:
        lines = path.read_text(errors="ignore").splitlines()
    except OSError:
        return 0, 0, []

    for line_no, raw in enumerate(lines, 1):
        try:
            row = json.loads(raw)
        except Exception:
            continue
        if row.get("type") != "response_item":
            continue
        payload = row.get("payload")
        if not isinstance(payload, dict):
            continue
        if payload.get("type") != "message" or payload.get("role") != "user":
            continue

        prompt = prompt_text_from_content(payload.get("content"))
        if not prompt or is_codex_control_message(prompt):
            continue
        timestamp = str(row.get("timestamp") or iso_now())
        parsed_ts = parse_ts(timestamp) or utc_now()
        if parsed_ts < cutoff_ts:
            continue
        key = event_key(path, line_no, timestamp, prompt)
        if key in processed:
            continue

        matches = sorted({word for word in re.findall(r"[a-z]+", prompt.lower()) if word in words})
        classifier = None
        classifier_enabled = os.environ.get("INTROSPECT_WAKE_CLASSIFIER", "1") != "0"
        if classifier_enabled and score_prompt is not None:
            try:
                classifier = score_prompt(
                    prompt,
                    source="codex",
                    old_trigger=bool(matches),
                    matched_words=matches,
                )
            except Exception as exc:
                classifier = {"error": f"{type(exc).__name__}: {str(exc)[:160]}"}
        classifier_available = bool(classifier and "score" in classifier)
        word_fallback_enabled = os.environ.get("INTROSPECT_TRIGGER_WORD_FALLBACK", "0") == "1"
        triggered = bool(classifier.get("triggered")) if classifier_available else (
            bool(matches) and word_fallback_enabled
        )
        wake_reason = "classifier" if classifier_available else (
            "trigger_word_fallback" if word_fallback_enabled else "classifier_unavailable"
        )
        event = {
            "event_id": key,
            "ts": parsed_ts.isoformat(timespec="seconds"),
            "observed_at": iso_now(),
            "source": "codex_transcript_scan",
            "version": version,
            "triggered": triggered,
            "wake_reason": wake_reason,
            "review_triggered": bool(matches) or bool(classifier and classifier.get("review")),
            "session_id": session_id,
            "cwd": cwd,
            "transcript_path": str(path),
            "transcript_line": line_no,
            "message_locator": f"{path}:{line_no}",
            "dedupe_key": key,
        }
        if classifier:
            event["classifier"] = classifier
        if matches:
            event["matched"] = matches
        if matches or triggered or event.get("review_triggered"):
            event["snippet"] = prompt[:300]
        if triggered:
            queued_event = dict(event)
            queued_event["prompt"] = prompt[:4000]
            queued.append(queued_event)
            triggered_events += 1

        if write_events:
            append_json(EVENTS, event)
        processed[key] = iso_now()
        new_events += 1

    return new_events, triggered_events, queued


def kick_worker() -> None:
    if REFLECT_MODE != "immediate":
        return
    try:
        subprocess.Popen(
            [sys.executable, str(WORKER), "--kick"],
            cwd=REPO,
            env=os.environ.copy(),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except Exception:
        append_json(
            FEEDBACK_DIR / "reflector-launch-errors.jsonl",
            {
                "ts": iso_now(),
                "worker": str(WORKER),
                "source": "codex_transcript_scan",
            },
        )


def trim_processed(processed: dict[str, str]) -> dict[str, str]:
    if len(processed) <= MAX_STATE_KEYS:
        return processed
    rows = sorted(processed.items(), key=lambda item: item[1], reverse=True)
    return dict(rows[:MAX_STATE_KEYS])


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--since-minutes", type=int, default=DEFAULT_SCAN_MINUTES)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-kick", action="store_true")
    args = parser.parse_args()

    state = read_json(STATE, {})
    processed = state.get("processed")
    if not isinstance(processed, dict):
        processed = {}

    words = active_trigger_words()
    version = git_version()
    cutoff_ts = utc_now() - dt.timedelta(minutes=max(args.since_minutes, 1))
    files = candidate_files(args.since_minutes)
    new_events = 0
    triggered_events = 0
    queued_events: list[dict] = []

    if args.dry_run:
        dry_processed = dict(processed)
        for path in files:
            new_count, triggered_count, queued = scan_file(
                path,
                dry_processed,
                words,
                version,
                cutoff_ts,
                write_events=False,
            )
            new_events += new_count
            triggered_events += triggered_count
            queued_events.extend(queued)
        print(
            "codex-transcript-scan: "
            f"files={len(files)} new_events={new_events} triggered={triggered_events} "
            f"queued={len(queued_events)} dry_run=True"
        )
        return 0

    for path in files:
        new_count, triggered_count, queued = scan_file(
            path,
            processed,
            words,
            version,
            cutoff_ts,
            write_events=True,
        )
        new_events += new_count
        triggered_events += triggered_count
        queued_events.extend(queued)

    if queued_events and REFLECT_MODE != "off":
        for event in queued_events:
            append_json(QUEUE, event)
        if not args.no_kick:
            kick_worker()

    state["processed"] = trim_processed(processed)
    state["last_scan_at"] = iso_now()
    state["last_scan_files"] = len(files)
    state["last_new_events"] = new_events
    state["last_triggered_events"] = triggered_events
    write_json(STATE, state)

    print(
        "codex-transcript-scan: "
        f"files={len(files)} new_events={new_events} triggered={triggered_events} "
        f"queued={len(queued_events) if REFLECT_MODE != 'off' else 0}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
