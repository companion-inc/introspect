#!/usr/bin/env python3
"""Single-worker batch reflector for trigger events.

The UserPromptSubmit hook only logs and queues. This worker is the deterministic
control plane: debounce a burst, take the queue, hold a lock while one reflector
agent runs, and requeue/schedule anything that arrives during cooldown.
"""

from __future__ import annotations

import argparse
import atexit
import datetime as dt
import difflib
import errno
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


REPO = Path(os.path.expanduser(os.environ.get("INTROSPECT_REPO", "~/Companion/Code/introspect")))
SKILLS_DIR = Path(os.path.expanduser(os.environ.get("INTROSPECT_SKILLS_DIR", str(REPO / "skills"))))
FEEDBACK_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_FEEDBACK_DIR", str(REPO / "feedback")))
)
PROFILE_DIR = Path(os.path.expanduser(os.environ.get("INTROSPECT_PROFILE_DIR", "~/.introspect/profile")))
PROFILE_SETTINGS = PROFILE_DIR / "settings.json"
QUEUE = FEEDBACK_DIR / "trigger-queue.jsonl"
LOCK = FEEDBACK_DIR / "reflector.lock"
STATE = FEEDBACK_DIR / "reflector-state.json"
LOG = FEEDBACK_DIR / "reflector.log"
BATCHES = FEEDBACK_DIR / "reflector-batches.jsonl"
LAST_PROMPT = FEEDBACK_DIR / "last-reflector-prompt.md"
PROMPTS_DIR = FEEDBACK_DIR / "reflector-prompts"
SURFACE_DIFFS_DIR = FEEDBACK_DIR / "surface-diffs"

DEBOUNCE_SECONDS = float(os.environ.get("TRIGGER_DEBOUNCE_SECONDS", "75"))
GLOBAL_COOLDOWN_SECONDS = float(os.environ.get("TRIGGER_COOLDOWN_SECONDS", "300"))
SESSION_COOLDOWN_SECONDS = float(os.environ.get("TRIGGER_SESSION_COOLDOWN_SECONDS", "900"))
STALE_LOCK_SECONDS = float(os.environ.get("TRIGGER_STALE_LOCK_SECONDS", "1800"))
REFLECTOR_TIMEOUT_SECONDS = float(os.environ.get("TRIGGER_REFLECTOR_TIMEOUT_SECONDS", "600"))
DRY_RUN = os.environ.get("TRIGGER_REFLECTOR_DRY_RUN") == "1"
DISABLE_SCHEDULE = os.environ.get("TRIGGER_DISABLE_SCHEDULE") == "1"
REFLECTOR_RUNNER = os.environ.get("INTROSPECT_REFLECTOR_RUNNER", "default").strip().lower() or "default"
REFLECTOR_CLAUDE_MODEL = os.environ.get("INTROSPECT_REFLECTOR_CLAUDE_MODEL", "")
REFLECTOR_CLAUDE_FALLBACK_MODEL = os.environ.get("INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL", "")
REFLECTOR_CODEX_MODEL = os.environ.get("INTROSPECT_REFLECTOR_CODEX_MODEL", "")
USAGE_SCAN_DAYS = float(os.environ.get("INTROSPECT_REFLECTOR_USAGE_DAYS", "3"))
USAGE_SCAN_FILES = int(os.environ.get("INTROSPECT_REFLECTOR_USAGE_FILES", "40"))
SURFACE_SCAN_MAX_DEPTH = int(os.environ.get("INTROSPECT_SURFACE_SCAN_MAX_DEPTH", "7"))
SURFACE_SCAN_MAX_FILE_BYTES = int(os.environ.get("INTROSPECT_SURFACE_SCAN_MAX_FILE_BYTES", "1000000"))
RUNNER_ALIASES = {
    "auto": "default",
    "most-used": "default",
    "most_used": "default",
}
SKIPPED_SURFACE_DIRS = {
    ".build",
    ".cache",
    ".git",
    ".next",
    ".swiftpm",
    "DerivedData",
    "__pycache__",
    "build",
    "cache",
    "dist",
    "node_modules",
    "plugins",
}


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="seconds")


def file_stamp() -> str:
    return utc_now().strftime("%Y%m%dT%H%M%SZ")


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


def append_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def clean_model_value(value: str | None) -> str:
    cleaned = (value or "").strip()
    if cleaned.lower() in {"", "default", "auto"}:
        return ""
    return cleaned


def selected_model_for_runner(runner: str) -> str:
    if runner == "claude":
        return clean_model_value(REFLECTOR_CLAUDE_MODEL)
    if runner == "codex":
        return clean_model_value(REFLECTOR_CODEX_MODEL)
    return ""


def selected_fallback_model_for_runner(runner: str) -> str:
    if runner == "claude":
        return clean_model_value(REFLECTOR_CLAUDE_FALLBACK_MODEL)
    return ""


def log(message: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{iso_now()} {message}\n")


def notifications_enabled() -> bool:
    if os.environ.get("INTROSPECT_NOTIFY") == "0":
        return False
    try:
        data = json.loads(PROFILE_SETTINGS.read_text())
    except Exception:
        return True
    if not isinstance(data, dict):
        return True
    return data.get("notifications_enabled", True) is not False


def notification_helper() -> Path | None:
    candidates = []
    configured = os.environ.get("INTROSPECT_NOTIFICATION_HELPER")
    if configured:
        candidates.append(Path(os.path.expanduser(configured)))
    candidates.append(Path("/Applications/Introspect.app/Contents/MacOS/Introspect"))
    candidates.append(REPO / ".build" / "Introspect.app" / "Contents" / "MacOS" / "Introspect")

    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def notify_with_app(title: str, message: str, helper: Path) -> bool:
    try:
        result = subprocess.run(
            [str(helper), "--post-notification", title, message],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        log(f"app notification helper failed: {exc!r}")
        return False

    if result.returncode == 0:
        return True

    output = (result.stderr or result.stdout or "").strip()
    if output:
        log(f"app notification helper exited {result.returncode}: {output[:500]}")
    else:
        log(f"app notification helper exited {result.returncode}")
    return False


def app_notifications_allowed(helper: Path) -> bool:
    try:
        result = subprocess.run(
            [str(helper), "--notification-status"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        log(f"app notification status failed: {exc!r}")
        return False

    status = (result.stdout or result.stderr or "").splitlines()
    first_line = status[0].strip() if status else ""
    if first_line in {"allowed by macOS", "delivered quietly by macOS", "temporarily allowed by macOS"}:
        return True
    if first_line:
        log(f"app notification helper not used: {first_line}")
    return False


def notify(title: str, message: str) -> None:
    if not notifications_enabled():
        return

    helper = notification_helper()
    if not helper:
        log("notification skipped: Introspect.app is not installed")
        return
    if not app_notifications_allowed(helper):
        log("notification skipped: Introspect.app is not allowed to send notifications (enable it in System Settings > Notifications)")
        return
    if notify_with_app(title, message, helper):
        log("notification delivered through Introspect.app")
        return
    log("notification failed: Introspect.app is allowed but posting did not succeed")


def matched_words(events: list[dict]) -> list[str]:
    words: set[str] = set()
    for event in events:
        for word in event.get("matched", []):
            if isinstance(word, str) and word.strip():
                words.add(word.strip())
    return sorted(words, key=str.lower)


def trigger_words_text(events: list[dict]) -> str:
    words = matched_words(events)
    return ", ".join(words)


def surface_scan_roots(events: list[dict] | None = None) -> list[Path]:
    home = Path.home()
    roots = [
        REPO,
        PROFILE_DIR,
        home / ".codex",
        home / ".claude",
        home / ".agents",
    ]
    for event in events or []:
        cwd = event.get("cwd")
        if isinstance(cwd, str) and cwd.strip():
            roots.append(Path(os.path.expanduser(cwd.strip())))
    seen: set[str] = set()
    existing: list[Path] = []
    for root in roots:
        try:
            resolved = root.expanduser().resolve()
        except OSError:
            continue
        if not resolved.exists():
            continue
        key = str(resolved)
        if key in seen:
            continue
        seen.add(key)
        existing.append(resolved)
    return existing


def path_contains(path: Path, parts: tuple[str, ...]) -> bool:
    path_parts = path.parts
    if len(parts) > len(path_parts):
        return False
    for index in range(0, len(path_parts) - len(parts) + 1):
        if path_parts[index : index + len(parts)] == parts:
            return True
    return False


def is_agent_surface_file(path: Path) -> bool:
    name = path.name
    if name in {"AGENTS.md", "AGENTS.override.md", "CLAUDE.md", "CLAUDE.local.md"}:
        return True
    if name == "index.json" and path.parent.name == "skills":
        return True
    if name == "SKILL.md" and "skills" in path.parts:
        return True
    if name.endswith(".md") and path_contains(path, (".claude", "rules")):
        return True
    return False


def surface_kind(path: Path) -> str:
    if path.name == "SKILL.md" or path_contains(path, ("skills",)):
        return "skill"
    if path_contains(path, (".claude", "rules")):
        return "agent_rule"
    return "agent_file"


def display_path(path: Path) -> str:
    try:
        home = Path.home().resolve()
        resolved = path.expanduser().resolve()
    except OSError:
        return str(path)
    text = str(resolved)
    home_text = str(home)
    if text == home_text:
        return "~"
    if text.startswith(home_text + "/"):
        return "~" + text[len(home_text) :]
    return text


def line_count_text(text: str) -> int:
    return len(text.splitlines())


def read_surface_text(path: Path) -> str | None:
    try:
        stat = path.stat()
        if stat.st_size > SURFACE_SCAN_MAX_FILE_BYTES:
            return f"<skipped: file is {stat.st_size} bytes>"
        return path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return "<skipped: non UTF-8 file>"
    except OSError:
        return None


def snapshot_agent_surfaces(events: list[dict] | None = None) -> dict[str, dict]:
    snapshot: dict[str, dict] = {}
    visited_dirs: set[str] = set()
    for root in surface_scan_roots(events):
        stack: list[tuple[Path, int]] = [(root, 0)]
        while stack:
            directory, depth = stack.pop()
            if depth > SURFACE_SCAN_MAX_DEPTH:
                continue
            try:
                resolved_dir = str(directory.resolve())
            except OSError:
                continue
            if resolved_dir in visited_dirs:
                continue
            visited_dirs.add(resolved_dir)
            try:
                entries = list(directory.iterdir())
            except OSError:
                continue
            for entry in entries:
                try:
                    is_dir = entry.is_dir()
                except OSError:
                    continue
                if is_dir:
                    if entry.name in SKIPPED_SURFACE_DIRS:
                        continue
                    stack.append((entry, depth + 1))
                    continue
                if not is_agent_surface_file(entry):
                    continue
                text = read_surface_text(entry)
                if text is None:
                    continue
                try:
                    key = str(entry.resolve())
                except OSError:
                    key = str(entry)
                snapshot[key] = {
                    "path": key,
                    "display_path": display_path(entry),
                    "kind": surface_kind(entry),
                    "line_count": line_count_text(text),
                    "text": text,
                }
    return snapshot


def write_surface_diff(before: dict[str, dict], after: dict[str, dict], path: Path, batch: dict) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    changes = []
    for item_path in sorted(set(before) | set(after)):
        old = before.get(item_path)
        new = after.get(item_path)
        old_text = old.get("text", "") if old else ""
        new_text = new.get("text", "") if new else ""
        if old_text == new_text:
            continue
        if old is None:
            change_type = "added"
        elif new is None:
            change_type = "deleted"
        else:
            change_type = "modified"
        label = (new or old or {}).get("display_path", item_path)
        diff_lines = difflib.unified_diff(
            old_text.splitlines(),
            new_text.splitlines(),
            fromfile=f"{label} before",
            tofile=f"{label} after",
            lineterm="",
        )
        changes.append(
            {
                "path": item_path,
                "display_path": label,
                "kind": (new or old or {}).get("kind", "agent_file"),
                "change_type": change_type,
                "before_line_count": old.get("line_count", 0) if old else 0,
                "after_line_count": new.get("line_count", 0) if new else 0,
                "diff": "\n".join(diff_lines),
            }
        )
    payload = {
        "schema_version": 1,
        "ts": iso_now(),
        "batch": batch,
        "changed_count": len(changes),
        "changes": changes,
    }
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
    return len(changes)


def available_reflector_runners() -> dict[str, str]:
    runners = {}
    for name in ("claude", "codex"):
        path = shutil.which(name)
        if path:
            runners[name] = path
    return runners


def prompt_text_from_codex_content(content) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict) and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return "\n".join(parts)


def is_codex_control_message(prompt: str) -> bool:
    stripped = prompt.lstrip()
    return (
        stripped.startswith("# AGENTS.md instructions for ")
        or stripped.startswith("<codex_internal_context ")
        or stripped.startswith("<turn_aborted>")
    )


def recent_jsonl_files(root: Path, pattern: str, cutoff: dt.datetime) -> list[Path]:
    if not root.exists():
        return []
    cutoff_mtime = cutoff.timestamp()
    files: list[Path] = []
    for path in root.rglob(pattern):
        try:
            if path.stat().st_mtime >= cutoff_mtime:
                files.append(path)
        except OSError:
            continue
    return sorted(files, key=lambda item: item.stat().st_mtime, reverse=True)[:USAGE_SCAN_FILES]


def count_recent_codex_usage(cutoff: dt.datetime) -> tuple[int, dt.datetime | None]:
    sessions_dir = Path.home() / ".codex" / "sessions"
    count = 0
    latest: dt.datetime | None = None
    for path in recent_jsonl_files(sessions_dir, "rollout-*.jsonl", cutoff):
        try:
            handle = path.open(errors="ignore")
        except OSError:
            continue
        with handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                payload = row.get("payload")
                if row.get("type") != "response_item" or not isinstance(payload, dict):
                    continue
                if payload.get("type") != "message" or payload.get("role") != "user":
                    continue
                prompt = prompt_text_from_codex_content(payload.get("content"))
                if not prompt or is_codex_control_message(prompt):
                    continue
                ts = parse_ts(row.get("timestamp"))
                if ts is None or ts < cutoff:
                    continue
                count += 1
                if latest is None or ts > latest:
                    latest = ts
    return count, latest


def count_recent_claude_usage(cutoff: dt.datetime) -> tuple[int, dt.datetime | None]:
    projects_dir = Path.home() / ".claude" / "projects"
    count = 0
    latest: dt.datetime | None = None
    for path in recent_jsonl_files(projects_dir, "*.jsonl", cutoff):
        try:
            handle = path.open(errors="ignore")
        except OSError:
            continue
        with handle:
            for line in handle:
                try:
                    row = json.loads(line)
                except Exception:
                    continue
                if row.get("type") != "user":
                    continue
                message = row.get("message")
                if not isinstance(message, dict) or message.get("role") != "user":
                    continue
                ts = parse_ts(row.get("timestamp"))
                if ts is None or ts < cutoff:
                    continue
                count += 1
                if latest is None or ts > latest:
                    latest = ts
    return count, latest


def select_default_runner(runners: dict[str, str]) -> tuple[str, str]:
    if not runners:
        raise RuntimeError("no reflector runner found; install claude or codex")
    if len(runners) == 1:
        name = next(iter(runners))
        return name, runners[name]

    cutoff = utc_now() - dt.timedelta(days=USAGE_SCAN_DAYS)
    usage = {
        "claude": count_recent_claude_usage(cutoff),
        "codex": count_recent_codex_usage(cutoff),
    }
    available_usage = {name: usage[name] for name in runners}
    max_count = max(count for count, _latest in available_usage.values())
    candidates = [name for name, (count, _latest) in available_usage.items() if count == max_count]
    if len(candidates) > 1:
        latest_by_name = {name: available_usage[name][1] or dt.datetime.min.replace(tzinfo=dt.timezone.utc) for name in candidates}
        max_latest = max(latest_by_name.values())
        candidates = [name for name in candidates if latest_by_name[name] == max_latest]
    if len(candidates) > 1:
        candidates = ["codex"] if "codex" in candidates else sorted(candidates)

    name = candidates[0]
    log(
        "default reflector runner selected "
        f"{name} (claude_usage={usage['claude'][0]}, codex_usage={usage['codex'][0]})"
    )
    return name, runners[name]


def select_reflector_runner() -> tuple[str, str]:
    runners = available_reflector_runners()
    runner = RUNNER_ALIASES.get(REFLECTOR_RUNNER, REFLECTOR_RUNNER)
    if runner == "default":
        return select_default_runner(runners)
    if runner not in {"claude", "codex"}:
        raise RuntimeError(f"invalid INTROSPECT_REFLECTOR_RUNNER={REFLECTOR_RUNNER!r}")
    path = runners.get(runner)
    if not path:
        raise RuntimeError(f"requested reflector runner {runner!r} is not on PATH")
    return runner, path


def build_reflector_command(runner: str, runner_path: str, prompt: str, allowed_tools: str) -> list[str]:
    if runner == "claude":
        cmd = [
            runner_path,
            "-p",
            prompt,
        ]
        model = selected_model_for_runner(runner)
        fallback_model = selected_fallback_model_for_runner(runner)
        if model:
            cmd.extend(["--model", model])
        if fallback_model:
            cmd.extend(["--fallback-model", fallback_model])
        cmd.extend(
            [
            "--permission-mode",
            "bypassPermissions",
            "--allowedTools",
            allowed_tools,
            ]
        )
        return cmd
    if runner == "codex":
        cmd = [
            runner_path,
            "exec",
            "--dangerously-bypass-approvals-and-sandbox",
            "-C",
            str(REPO),
        ]
        model = selected_model_for_runner(runner)
        if model:
            cmd.extend(["--model", model])
        cmd.append(prompt)
        return cmd
    raise RuntimeError(f"unsupported reflector runner {runner!r}")


def pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except Exception:
        return False


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def save_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def acquire_lock() -> bool:
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    existing = read_json(LOCK, {})
    if existing:
        pid = int(existing.get("pid") or 0)
        started = parse_ts(existing.get("started_at"))
        age = (utc_now() - started).total_seconds() if started else STALE_LOCK_SECONDS + 1
        if pid and pid_alive(pid) and age < STALE_LOCK_SECONDS:
            log(f"worker already running pid={pid}; exiting")
            return False
        try:
            LOCK.unlink()
            log(f"removed stale lock pid={pid or 'unknown'} age={age:.0f}s")
        except FileNotFoundError:
            pass

    try:
        fd = os.open(str(LOCK), os.O_WRONLY | os.O_CREAT | os.O_EXCL)
    except OSError as exc:
        if exc.errno == errno.EEXIST:
            log("lost lock race; exiting")
            return False
        raise

    with os.fdopen(fd, "w") as f:
        json.dump({"pid": os.getpid(), "started_at": iso_now()}, f)
        f.write("\n")

    def cleanup() -> None:
        current = read_json(LOCK, {})
        if int(current.get("pid") or 0) == os.getpid():
            try:
                LOCK.unlink()
            except FileNotFoundError:
                pass

    atexit.register(cleanup)
    return True


def take_queue() -> list[dict]:
    if not QUEUE.exists():
        return []
    processing = FEEDBACK_DIR / f"trigger-queue.processing.{os.getpid()}.jsonl"
    try:
        os.replace(QUEUE, processing)
    except FileNotFoundError:
        return []

    events: list[dict] = []
    with processing.open() as f:
        for line in f:
            try:
                event = json.loads(line)
            except Exception:
                continue
            if event.get("triggered"):
                events.append(event)
    try:
        processing.unlink()
    except FileNotFoundError:
        pass
    return events


def requeue(events: list[dict]) -> None:
    if not events:
        return
    for event in events:
        append_json(QUEUE, event)


def session_key(event: dict) -> str:
    return (
        event.get("session_id")
        or event.get("transcript_path")
        or event.get("cwd")
        or "unknown"
    )


def global_cooldown_remaining(state: dict) -> float:
    now = utc_now()
    last_global = parse_ts(state.get("last_run_at"))
    if last_global:
        remaining = GLOBAL_COOLDOWN_SECONDS - (now - last_global).total_seconds()
        if remaining > 0:
            return remaining
    return 0.0


def split_by_session_cooldown(state: dict, events: list[dict]) -> tuple[list[dict], list[dict], float]:
    now = utc_now()
    sessions = state.get("sessions", {})
    eligible: list[dict] = []
    blocked: list[dict] = []
    waits: list[float] = []
    for event in events:
        key = session_key(event)
        last_session = parse_ts(sessions.get(key))
        if last_session:
            remaining = SESSION_COOLDOWN_SECONDS - (now - last_session).total_seconds()
            if remaining > 0:
                blocked.append(event)
                waits.append(remaining)
                continue
        eligible.append(event)
    return eligible, blocked, min(waits) if waits else 0.0


def schedule_retry(delay: float, state: dict) -> None:
    if DISABLE_SCHEDULE or delay <= 0:
        return
    delay = min(max(int(delay) + 1, 1), int(max(SESSION_COOLDOWN_SECONDS, GLOBAL_COOLDOWN_SECONDS, 60)))
    scheduled_for = utc_now() + dt.timedelta(seconds=delay)
    existing = parse_ts(state.get("scheduled_retry_at"))
    if existing and existing > utc_now():
        return
    state["scheduled_retry_at"] = scheduled_for.isoformat(timespec="seconds")
    save_json(STATE, state)

    command = (
        f"sleep {delay}; "
        f"{shlex.quote(sys.executable)} {shlex.quote(str(Path(__file__).resolve()))} --scheduled "
        f">> {shlex.quote(str(LOG))} 2>&1"
    )
    env = os.environ.copy()
    env["INTROSPECT_REFLECTOR"] = "1"
    subprocess.Popen(
        ["/bin/sh", "-c", command],
        cwd=REPO,
        env=env,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    log(f"scheduled retry in {delay}s")


def build_prompt(events: list[dict]) -> str:
    event_lines = []
    for i, event in enumerate(events, 1):
        visible = {
            "n": i,
            "ts": event.get("ts"),
            "version": event.get("version"),
            "session_id": event.get("session_id"),
            "cwd": event.get("cwd"),
            "transcript_path": event.get("transcript_path"),
            "matched": event.get("matched", []),
            "snippet": event.get("snippet", ""),
        }
        event_lines.append(json.dumps(visible, ensure_ascii=False))

    transcript_paths = sorted({event.get("transcript_path") for event in events if event.get("transcript_path")})
    transcript_block = "\n".join(f"- {path}" for path in transcript_paths) or "- none supplied; use session_id/cwd from events"

    return f"""You are the Introspect trigger reflector.

A batch of trigger-word events fired. The regex is broad recall only. Judge whether each event reflects a real agent-behavior failure or just casual register / external venting. Do not change anything for false positives.

Queued events:
{chr(10).join(event_lines)}

Transcript paths to inspect:
{transcript_block}

Agent loop repo:
- {REPO}

Skills directory:
- {SKILLS_DIR}

Workflow:
1. Read the recent turns for the relevant transcript/session and identify the agent behavior that caused the trigger, not the wording of the user's message.
2. Run {REPO}/hooks/trigger-stats.sh and compare the current prompt version against prior versions.
3. Classify the change target as exactly one of: no_change, core_prompt, project_prompt, profile_memory, skill_new, skill_update, project_skill_new, project_skill_update, skill_prune.
4. Use core_prompt only for an always-loaded invariant that should apply across nearly every task. Before editing AGENTS.md, read skills/agent-md-creator/SKILL.md for placement and skills/writing-agent-prompt/SKILL.md for wording, then verify with a realistic response probe drawn from the failure transcript.
5. Use project_prompt for repo-specific behavior. Create or update the target repo's AGENTS.md for shared guidance, create CLAUDE.md as @AGENTS.md plus Claude-only additions when Claude should read it, and use CLAUDE.local.md for private project notes.
6. Use profile_memory for durable facts, preferences, user vocabulary, or machine/project state that should be remembered but should not change agent behavior globally. Write it under ~/.introspect/profile only when it is directly supported by the transcript.
7. Use skill_new or skill_update only for repeatable procedures, tool workflows, domain references, scripts, or assets that future agents should load on demand. Do not create a skill from one noisy event unless it captures a recurring workflow or a corrected procedure that will likely repeat.
8. Prefer updating an existing umbrella skill or support file over creating a narrow duplicate. Use project_skill_new or project_skill_update when the workflow belongs to one codebase; write Codex project skills under .agents/skills/<slug>/SKILL.md and Claude project skills under .claude/skills/<slug>/SKILL.md in that target repo.
9. Use skill_prune for stale, duplicated, overbroad, unsupported, or harmful skills. Before any skill operation, read skills/skill-creator/SKILL.md, its source map, the skills index, and the closest existing skill. Prefer updating or pruning a close skill over creating a duplicate.
10. For user-wide skill changes, write or edit a self-contained skills/<slug>/SKILL.md in this repo, update skills/index.json, and run INTROSPECT_SKILLS_DIR={SKILLS_DIR} {REPO}/scripts/validate-skills.py. For project skills, validate the SKILL.md frontmatter and verify the relevant agent can discover it. For skill_prune, prefer marking status deprecated or narrowing activation before deleting files.
11. If the trigger rate rose after a recent AGENTS.md change, prefer reverting or narrowing that change over adding another rule.
12. Commit with a behavioral message and push.
13. If no change is justified, make no file changes and say why in the log output.

Constraints:
- One batch, one decision. Do not spawn more agents.
- Do not edit for casual profanity, slurs used as examples, or anger about an external system.
- Keep changes short and reversible.
- In log output, use current Introspect vocabulary only: trigger, trigger-word event, Runs, and reflector run. Do not introduce deprecated product labels.
- Do not use generic trigger-language placeholders in skills. Use activation_signals.
"""


def invoke_reflector(events: list[dict]) -> int:
    prompt = build_prompt(events)
    before_surfaces = snapshot_agent_surfaces(events)
    run_id = f"{file_stamp()}-{os.getpid()}"
    prompt_path = PROMPTS_DIR / f"{run_id}.md"
    surface_diff_path = SURFACE_DIFFS_DIR / f"{run_id}.json"
    LAST_PROMPT.parent.mkdir(parents=True, exist_ok=True)
    PROMPTS_DIR.mkdir(parents=True, exist_ok=True)
    LAST_PROMPT.write_text(prompt)
    prompt_path.write_text(prompt)

    runner = "dry-run"
    runner_path = ""
    model = ""
    fallback_model = ""
    if not DRY_RUN:
        runner, runner_path = select_reflector_runner()
        model = selected_model_for_runner(runner)
        fallback_model = selected_fallback_model_for_runner(runner)

    batch = {
        "ts": iso_now(),
        "event_count": len(events),
        "matched": matched_words(events),
        "sessions": sorted({session_key(event) for event in events}),
        "dry_run": DRY_RUN,
        "runner": runner,
        "model": model,
        "fallback_model": fallback_model,
        "prompt_path": str(prompt_path),
        "surface_diff_path": str(surface_diff_path),
    }
    append_json(BATCHES, batch)

    if DRY_RUN:
        write_surface_diff(before_surfaces, before_surfaces, surface_diff_path, batch)
        log(f"DRY RUN would invoke reflector for {len(events)} event(s)")
        return 0

    allowed_tools = ",".join(
        [
            "Read",
            "Edit",
            "Write",
            "Grep",
            "Glob",
            "WebSearch",
            "WebFetch",
            "Bash(git *)",
            "Bash(*trigger-stats.sh)",
            "Bash(*validate-skills.py)",
            "Bash(mkdir -p *)",
        ]
    )
    env = os.environ.copy()
    env["INTROSPECT_REFLECTOR"] = "1"
    cmd = build_reflector_command(runner, runner_path, prompt, allowed_tools)
    model_note = f" model={model}" if model else " model=cli-default"
    if fallback_model:
        model_note += f" fallback={fallback_model}"
    log(f"invoking {runner} reflector for {len(events)} event(s){model_note}")
    words = trigger_words_text(events)
    body = f"{runner} reflector spawned for {len(events)} trigger event(s)"
    if words:
        body = f"{body}: {words}"
        log(f"trigger words: {words}")
    notify("Introspect", body)
    with LOG.open("a") as log_file:
        display_cmd = " ".join(shlex.quote(part) for part in cmd)
        display_cmd = display_cmd.replace(shlex.quote(prompt), "<batch-prompt>")
        log_file.write(f"{iso_now()} command: {display_cmd}\n")
        log_file.flush()
        result = subprocess.run(
            cmd,
            cwd=REPO,
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=REFLECTOR_TIMEOUT_SECONDS,
        )
    after_surfaces = snapshot_agent_surfaces(events)
    changed_count = write_surface_diff(before_surfaces, after_surfaces, surface_diff_path, batch)
    log(f"surface diff recorded changes={changed_count} path={surface_diff_path}")
    log(f"reflector exited code={result.returncode}")
    return result.returncode


def update_state_after_run(state: dict, events: list[dict]) -> None:
    now = iso_now()
    state["last_run_at"] = now
    state["scheduled_retry_at"] = None
    sessions = state.setdefault("sessions", {})
    for event in events:
        sessions[session_key(event)] = now
    save_json(STATE, state)


def clear_scheduled_retry_if_idle() -> None:
    state = read_json(STATE, {})
    if state.get("scheduled_retry_at"):
        state["scheduled_retry_at"] = None
        save_json(STATE, state)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kick", action="store_true")
    parser.add_argument("--scheduled", action="store_true")
    parser.add_argument("--nightly", action="store_true")
    parser.add_argument("--test-notification", action="store_true")
    args = parser.parse_args()

    if args.test_notification:
        notify("Introspect", "Test notification from the Introspect worker.")
        return 0

    if not acquire_lock():
        return 0

    if not args.nightly and DEBOUNCE_SECONDS > 0:
        log(f"debouncing for {DEBOUNCE_SECONDS:.1f}s")
        time.sleep(DEBOUNCE_SECONDS)

    events = take_queue()
    if not events:
        clear_scheduled_retry_if_idle()
        log("no queued trigger events")
        return 0

    state = read_json(STATE, {})
    blocked: list[dict] = []
    session_wait = 0.0
    if args.nightly:
        log(f"nightly batch processing {len(events)} queued event(s)")
        eligible = events
    else:
        remaining = global_cooldown_remaining(state)
        if remaining > 0:
            log(f"global cooldown active for {remaining:.0f}s; requeueing {len(events)} event(s)")
            requeue(events)
            schedule_retry(remaining, state)
            return 0

        eligible, blocked, session_wait = split_by_session_cooldown(state, events)
        if blocked:
            log(
                f"session cooldown blocked {len(blocked)} event(s) for {session_wait:.0f}s; "
                f"{len(eligible)} event(s) eligible"
            )
            requeue(blocked)
        if not eligible:
            schedule_retry(session_wait, state)
            return 0

    try:
        code = invoke_reflector(eligible)
    except subprocess.TimeoutExpired:
        log("reflector timed out; requeueing batch")
        requeue(eligible)
        return 124
    except Exception as exc:
        log(f"reflector failed before launch: {exc!r}; requeueing batch")
        requeue(eligible)
        return 1

    if code != 0:
        log(f"reflector returned nonzero code={code}; requeueing batch")
        requeue(eligible)
        if not args.nightly:
            state = read_json(STATE, {})
            schedule_retry(GLOBAL_COOLDOWN_SECONDS, state)
        return code

    update_state_after_run(state, eligible)
    if not args.nightly and QUEUE.exists():
        state = read_json(STATE, {})
        delay = max(GLOBAL_COOLDOWN_SECONDS, session_wait if blocked else 0)
        schedule_retry(delay, state)
    return code


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    raise SystemExit(main())
