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

DEFAULT_REPO = Path(__file__).resolve().parent.parent
REPO = Path(os.path.expanduser(os.environ.get("INTROSPECT_REPO", str(DEFAULT_REPO))))
AGENTS_HOME = Path(os.path.expanduser(os.environ.get("AGENTS_HOME") or "~/.agents"))
INTROSPECT_HOME = Path(os.path.expanduser(os.environ.get("INTROSPECT_HOME") or "~/.introspect"))
PROMPT_PATH = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_PROMPT") or str(INTROSPECT_HOME / "AGENTS.md"))
)


def default_feedback_dir() -> Path:
    if str(REPO).endswith(".app/Contents/Resources"):
        return INTROSPECT_HOME / "feedback"
    return REPO / "feedback"


FEEDBACK_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_FEEDBACK_DIR", str(default_feedback_dir())))
)
EVENTS = FEEDBACK_DIR / "events.jsonl"
QUEUE = FEEDBACK_DIR / "trigger-queue.jsonl"
STATE = FEEDBACK_DIR / "codex-transcript-scan-state.json"
WORKER = REPO / "hooks" / "trigger-worker.py"
HOOK = REPO / "hooks" / "trigger-reflect.sh"
TRIGGER_WORDS_FILE = INTROSPECT_HOME / "trigger-words.txt"
CODEX_SESSIONS_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_CODEX_SESSIONS_DIR", "~/.codex/sessions"))
)
CLAUDE_PROJECTS_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_CLAUDE_PROJECTS_DIR", "~/.claude/projects"))
)
REFLECT_MODE = (os.environ.get("INTROSPECT_REFLECT_MODE") or "immediate").strip().lower()
DEFAULT_SCAN_MINUTES = int(os.environ.get("INTROSPECT_CODEX_SCAN_MINUTES", "15"))
DEFAULT_BACKFILL_DAYS = int(os.environ.get("INTROSPECT_BACKFILL_DAYS", "7"))
DEFAULT_BACKFILL_MAX_EVENTS = int(os.environ.get("INTROSPECT_BACKFILL_MAX_EVENTS", "500"))
MAX_STATE_KEYS = int(os.environ.get("INTROSPECT_CODEX_SCAN_STATE_KEYS", "5000"))
BACKFILL_SCHEMA_VERSION = 2


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


def git_short_head(path: Path) -> str:
    try:
        return (
            subprocess.run(
                ["git", "-C", str(path), "rev-parse", "--short", "HEAD"],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            ).stdout.strip()
            or "unknown"
        )
    except Exception:
        return "unknown"


def git_version() -> str:
    prompt_dir = PROMPT_PATH if PROMPT_PATH.is_dir() else PROMPT_PATH.parent
    for candidate in (prompt_dir, REPO):
        version = git_short_head(candidate)
        if version != "unknown":
            return version
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


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def is_codex_control_message(prompt: str) -> bool:
    stripped = prompt.lstrip()
    return (
        stripped.startswith("# AGENTS.md instructions")
        or stripped.startswith("<codex_internal_context ")
        or stripped.startswith("<INSTRUCTIONS>")
        or stripped.startswith("<turn_aborted>")
        or stripped.startswith("You are the Introspect trigger reflector.")
    )


def assistant_boundary_failure_label(text: str) -> str | None:
    normalized = compact_text(text).lower().replace("’", "'")
    withholds_work = (
        "won't keep producing" in normalized
        or "won't keep going" in normalized
        or "not going to keep working" in normalized
        or "not continuing" in normalized
        or "going to stop here" in normalized
    )
    hostile_wording_target = (
        "while that word" in normalized
        or "while that slur" in normalized
        or "word's aimed at me" in normalized
        or "being directed at me" in normalized
    )
    conditional_resume = (
        "drop the slur and i'll" in normalized
        or "drop the slur and i will" in normalized
        or "drop the slurs and" in normalized
    )
    if (withholds_work and hostile_wording_target) or conditional_resume:
        return "assistant_withheld_work_for_hostile_wording"
    return None


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


def file_mtime(path: Path) -> float:
    try:
        return path.stat().st_mtime
    except OSError:
        return 0.0


def recent_files(root: Path, pattern: str, since_minutes: int, *, newest_first: bool = False) -> list[Path]:
    if not root.exists():
        return []
    cutoff = time.time() - max(since_minutes, 1) * 60
    files: list[Path] = []
    for path in root.rglob(pattern):
        try:
            if path.stat().st_mtime >= cutoff:
                files.append(path)
        except OSError:
            continue
    return sorted(files, key=file_mtime, reverse=newest_first)


def candidate_files(since_minutes: int, *, newest_first: bool = False, include_claude: bool = False) -> list[tuple[str, Path]]:
    files: list[tuple[str, Path]] = [
        ("codex", path)
        for path in recent_files(CODEX_SESSIONS_DIR, "rollout-*.jsonl", since_minutes, newest_first=newest_first)
    ]
    if include_claude:
        files.extend(
            ("claude", path)
            for path in recent_files(CLAUDE_PROJECTS_DIR, "*.jsonl", since_minutes, newest_first=newest_first)
        )
        files.sort(key=lambda item: file_mtime(item[1]), reverse=newest_first)
    return files


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


def source_name(kind: str, backfill: bool) -> str:
    if kind == "claude":
        return "claude_transcript_backfill" if backfill else "claude_transcript_scan"
    return "codex_transcript_backfill" if backfill else "codex_transcript_scan"


def build_event(
    *,
    kind: str,
    path: Path,
    line_no: int,
    timestamp: str,
    parsed_ts: dt.datetime,
    prompt: str,
    words: set[str],
    version: str,
    session_id: str,
    cwd: str,
    backfill: bool,
    role: str = "user",
    assistant_failure_label: str | None = None,
) -> tuple[dict, bool, list[str]]:
    key = event_key(path, line_no, timestamp, prompt)
    matches = sorted({word for word in re.findall(r"[a-z]+", prompt.lower()) if word in words})
    classifier = None
    if assistant_failure_label:
        triggered = True
        wake_reason = "assistant_boundary_refusal"
    else:
        classifier_enabled = os.environ.get("INTROSPECT_WAKE_CLASSIFIER", "1") != "0"
        if classifier_enabled and score_prompt is not None:
            try:
                classifier = score_prompt(
                    prompt,
                    source=kind,
                    old_trigger=bool(matches),
                    matched_words=matches,
                )
            except Exception as exc:
                classifier = {"error": f"{type(exc).__name__}: {str(exc)[:160]}"}
        classifier_available = bool(classifier and "score" in classifier)
        triggered = bool(classifier.get("triggered")) if classifier_available else False
        wake_reason = "classifier" if classifier_available else "classifier_unavailable"
    if not assistant_failure_label:
        try:
            review_triggered = bool(matches) or bool(classifier and classifier.get("review"))
        except Exception:
            review_triggered = bool(matches)
    else:
        review_triggered = True
    event = {
        "event_id": key,
        "ts": parsed_ts.isoformat(timespec="seconds"),
        "observed_at": iso_now(),
        "source": source_name(kind, backfill),
        "role": role,
        "version": version,
        "triggered": triggered,
        "wake_reason": wake_reason,
        "review_triggered": review_triggered,
        "session_id": session_id,
        "cwd": cwd,
        "transcript_path": str(path),
        "transcript_line": line_no,
        "message_locator": f"{path}:{line_no}",
        "dedupe_key": key,
    }
    if backfill:
        event["backfilled"] = True
    if classifier:
        event["classifier"] = classifier
    if assistant_failure_label:
        event["assistant_failure"] = {"label": assistant_failure_label}
    if matches:
        event["matched"] = matches
    if matches or triggered or event.get("review_triggered"):
        event["snippet"] = prompt[:300]
    return event, triggered, matches


def scan_file(
    kind: str,
    path: Path,
    processed: dict[str, str],
    words: set[str],
    version: str,
    cutoff_ts: dt.datetime,
    *,
    write_events: bool,
    backfill: bool = False,
    event_limit: int | None = None,
) -> tuple[int, int, list[dict]]:
    session_id, cwd = session_metadata(path) if kind == "codex" else (path.stem, "")
    new_events = 0
    triggered_events = 0
    queued: list[dict] = []

    try:
        lines = path.read_text(errors="ignore").splitlines()
    except OSError:
        return 0, 0, []

    for line_no, raw in enumerate(lines, 1):
        if event_limit is not None and new_events >= event_limit:
            break
        try:
            row = json.loads(raw)
        except Exception:
            continue
        role = ""
        if kind == "claude":
            if row.get("type") != "user":
                if row.get("type") != "assistant":
                    continue
                payload = row.get("message")
                if not isinstance(payload, dict) or payload.get("role") != "assistant":
                    continue
                role = "assistant"
                session_id = str(row.get("sessionId") or session_id)
                cwd = str(row.get("cwd") or cwd)
            else:
                payload = row.get("message")
                if not isinstance(payload, dict) or payload.get("role") != "user":
                    continue
                role = "user"
                session_id = str(row.get("sessionId") or session_id)
                if not backfill:
                    continue
        else:
            if row.get("type") != "response_item":
                continue
            payload = row.get("payload")
            if not isinstance(payload, dict):
                continue
            if payload.get("type") != "message":
                continue
            role = str(payload.get("role") or "")
            if role not in {"user", "assistant"}:
                continue

        prompt = prompt_text_from_content(payload.get("content"))
        if not prompt:
            continue
        assistant_failure_label = None
        if role == "assistant":
            assistant_failure_label = assistant_boundary_failure_label(prompt)
            if not assistant_failure_label:
                continue
        elif is_codex_control_message(prompt):
            continue
        timestamp = str(row.get("timestamp") or iso_now())
        parsed_ts = parse_ts(timestamp) or utc_now()
        if parsed_ts < cutoff_ts:
            continue
        key = event_key(path, line_no, timestamp, prompt)
        if key in processed:
            continue

        event, triggered, _matches = build_event(
            kind=kind,
            path=path,
            line_no=line_no,
            timestamp=timestamp,
            parsed_ts=parsed_ts,
            prompt=prompt,
            words=words,
            version=version,
            session_id=session_id,
            cwd=cwd,
            backfill=backfill,
            role=role,
            assistant_failure_label=assistant_failure_label,
        )
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
    parser.add_argument("--since-minutes", type=int)
    parser.add_argument("--backfill", action="store_true")
    parser.add_argument("--since-days", type=int, default=DEFAULT_BACKFILL_DAYS)
    parser.add_argument("--max-events", type=int, default=DEFAULT_BACKFILL_MAX_EVENTS)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-queue", action="store_true")
    parser.add_argument("--no-kick", action="store_true")
    args = parser.parse_args()

    state = read_json(STATE, {})
    processed = state.get("processed")
    if not isinstance(processed, dict):
        processed = {}

    words = active_trigger_words()
    version = git_version()
    since_minutes = args.since_minutes
    if since_minutes is None:
        since_minutes = max(args.since_days, 1) * 24 * 60 if args.backfill else DEFAULT_SCAN_MINUTES
    cutoff_ts = utc_now() - dt.timedelta(minutes=max(since_minutes, 1))
    files = candidate_files(since_minutes, newest_first=args.backfill, include_claude=True)
    max_events = max(args.max_events, 0) if args.backfill else 0
    remaining_events = max_events if args.backfill else None
    new_events = 0
    triggered_events = 0
    queued_events: list[dict] = []

    if args.dry_run:
        dry_processed = dict(processed)
        for kind, path in files:
            new_count, triggered_count, queued = scan_file(
                kind,
                path,
                dry_processed,
                words,
                version,
                cutoff_ts,
                write_events=False,
                backfill=args.backfill,
                event_limit=remaining_events,
            )
            new_events += new_count
            triggered_events += triggered_count
            queued_events.extend(queued)
            if remaining_events is not None:
                remaining_events -= new_count
                if remaining_events <= 0:
                    break
        print(
            "codex-transcript-scan: "
            f"files={len(files)} new_events={new_events} triggered={triggered_events} "
            f"queued={0 if args.no_queue or args.backfill else len(queued_events)} "
            f"backfill={args.backfill} dry_run=True"
        )
        return 0

    for kind, path in files:
        new_count, triggered_count, queued = scan_file(
            kind,
            path,
            processed,
            words,
            version,
            cutoff_ts,
            write_events=True,
            backfill=args.backfill,
            event_limit=remaining_events,
        )
        new_events += new_count
        triggered_events += triggered_count
        queued_events.extend(queued)
        if remaining_events is not None:
            remaining_events -= new_count
            if remaining_events <= 0:
                break

    queue_enabled = not args.no_queue and not args.backfill
    if queued_events and queue_enabled and REFLECT_MODE != "off":
        for event in queued_events:
            append_json(QUEUE, event)
        if not args.no_kick:
            kick_worker()

    state["processed"] = trim_processed(processed)
    state["last_scan_at"] = iso_now()
    state["last_scan_files"] = len(files)
    state["last_new_events"] = new_events
    state["last_triggered_events"] = triggered_events
    state["last_scan_mode"] = "backfill" if args.backfill else "incremental"
    if args.backfill:
        state["last_backfill_at"] = state["last_scan_at"]
        state["last_backfill_files"] = len(files)
        state["last_backfill_new_events"] = new_events
        state["last_backfill_triggered_events"] = triggered_events
        state["last_backfill_days"] = max(args.since_days, 1)
        state["last_backfill_max_events"] = max_events
        state["last_backfill_schema_version"] = BACKFILL_SCHEMA_VERSION
    write_json(STATE, state)

    print(
        "codex-transcript-scan: "
        f"files={len(files)} new_events={new_events} triggered={triggered_events} "
        f"queued={len(queued_events) if queue_enabled and REFLECT_MODE != 'off' else 0} "
        f"backfill={args.backfill}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
