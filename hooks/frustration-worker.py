#!/usr/bin/env python3
"""Single-worker batch reflector for frustration events.

The UserPromptSubmit hook only logs and queues. This worker is the deterministic
control plane: debounce a burst, take the queue, hold a lock while one reflector
agent runs, and requeue/schedule anything that arrives during cooldown.
"""

from __future__ import annotations

import argparse
import atexit
import datetime as dt
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


REPO = Path(os.path.expanduser(os.environ.get("INTROSPECT_REPO", "~/Projects/introspect")))
SKILLS_DIR = Path(os.path.expanduser(os.environ.get("INTROSPECT_SKILLS_DIR", str(REPO / "skills"))))
FEEDBACK_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_FEEDBACK_DIR", str(REPO / "feedback")))
)
QUEUE = FEEDBACK_DIR / "frustration-queue.jsonl"
LOCK = FEEDBACK_DIR / "reflector.lock"
STATE = FEEDBACK_DIR / "reflector-state.json"
LOG = FEEDBACK_DIR / "reflector.log"
BATCHES = FEEDBACK_DIR / "reflector-batches.jsonl"
LAST_PROMPT = FEEDBACK_DIR / "last-reflector-prompt.md"

DEBOUNCE_SECONDS = float(os.environ.get("FRUSTRATION_DEBOUNCE_SECONDS", "75"))
GLOBAL_COOLDOWN_SECONDS = float(os.environ.get("FRUSTRATION_COOLDOWN_SECONDS", "300"))
SESSION_COOLDOWN_SECONDS = float(os.environ.get("FRUSTRATION_SESSION_COOLDOWN_SECONDS", "900"))
STALE_LOCK_SECONDS = float(os.environ.get("FRUSTRATION_STALE_LOCK_SECONDS", "1800"))
REFLECTOR_TIMEOUT_SECONDS = float(os.environ.get("FRUSTRATION_REFLECTOR_TIMEOUT_SECONDS", "600"))
DRY_RUN = os.environ.get("FRUSTRATION_REFLECTOR_DRY_RUN") == "1"
DISABLE_SCHEDULE = os.environ.get("FRUSTRATION_DISABLE_SCHEDULE") == "1"
REFLECTOR_RUNNER = os.environ.get("INTROSPECT_REFLECTOR_RUNNER", "default").strip().lower() or "default"
USAGE_SCAN_DAYS = float(os.environ.get("INTROSPECT_REFLECTOR_USAGE_DAYS", "3"))
USAGE_SCAN_FILES = int(os.environ.get("INTROSPECT_REFLECTOR_USAGE_FILES", "40"))
RUNNER_ALIASES = {
    "auto": "default",
    "most-used": "default",
    "most_used": "default",
}


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


def append_json(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def log(message: str) -> None:
    LOG.parent.mkdir(parents=True, exist_ok=True)
    with LOG.open("a") as f:
        f.write(f"{iso_now()} {message}\n")


def applescript_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(title: str, message: str) -> None:
    if os.environ.get("INTROSPECT_NOTIFY") == "0":
        return
    try:
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                (
                    "display notification "
                    f"{applescript_string(message)} "
                    f"with title {applescript_string(title)}"
                ),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=5,
            check=False,
        )
    except Exception as exc:
        log(f"notification failed: {exc!r}")


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
        return [
            runner_path,
            "-p",
            prompt,
            "--permission-mode",
            "bypassPermissions",
            "--allowedTools",
            allowed_tools,
        ]
    if runner == "codex":
        return [
            runner_path,
            "exec",
            "--sandbox",
            "danger-full-access",
            "--ask-for-approval",
            "never",
            "--search",
            "-C",
            str(REPO),
            prompt,
        ]
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
    processing = FEEDBACK_DIR / f"frustration-queue.processing.{os.getpid()}.jsonl"
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
            if event.get("frustrated"):
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

    return f"""You are the Introspect frustration reflector.

A batch of user-frustration tripwires fired. The regex is broad recall only. Judge whether each event is genuine frustration at agent behavior or just casual register / external venting. Do not change anything for false positives.

Queued events:
{chr(10).join(event_lines)}

Transcript paths to inspect:
{transcript_block}

Agent loop repo:
- {REPO}

Skills directory:
- {SKILLS_DIR}

Workflow:
1. Read the recent turns for the relevant transcript/session and identify the agent behavior that caused the frustration, not the wording of the user's message.
2. Run {REPO}/hooks/frustration-stats.sh and compare the current prompt version against prior versions.
3. Classify the change target as exactly one of: no_change, core_prompt, project_prompt, profile_memory, skill_new, skill_update, project_skill_new, project_skill_update, skill_prune.
4. Use core_prompt only for an always-loaded invariant that should apply across nearly every task. Before editing AGENTS.md, read skills/agent-md-creator/SKILL.md for placement and skills/writing-agent-prompt/SKILL.md for wording, then verify with a realistic response probe drawn from the failure transcript.
5. Use project_prompt for repo-specific behavior. Create or update the target repo's AGENTS.md for shared guidance, create CLAUDE.md as @AGENTS.md plus Claude-only additions when Claude should read it, and use CLAUDE.local.md for private project notes.
6. Use profile_memory for durable facts, preferences, user vocabulary, or machine/project state that should be remembered but should not change agent behavior globally. Write it under ~/.introspect/profile only when it is directly supported by the transcript.
7. Use skill_new or skill_update only for repeatable procedures, tool workflows, domain references, scripts, or assets that future agents should load on demand. Do not create a skill from one noisy event unless it captures a recurring workflow or a corrected procedure that will likely repeat.
8. Prefer updating an existing umbrella skill or support file over creating a narrow duplicate. Use project_skill_new or project_skill_update when the workflow belongs to one codebase; write Codex project skills under .agents/skills/<slug>/SKILL.md and Claude project skills under .claude/skills/<slug>/SKILL.md in that target repo.
9. Use skill_prune for stale, duplicated, overbroad, unsupported, or harmful skills. Before any skill operation, read skills/skill-creator/SKILL.md, its source map, the skills index, and the closest existing skill. Prefer updating or pruning a close skill over creating a duplicate.
10. For user-wide skill changes, write or edit a self-contained skills/<slug>/SKILL.md in this repo, update skills/index.json, and run INTROSPECT_SKILLS_DIR={SKILLS_DIR} {REPO}/scripts/validate-skills.py. For project skills, validate the SKILL.md frontmatter and verify the relevant agent can discover it. For skill_prune, prefer marking status deprecated or narrowing activation before deleting files.
11. If the frustration rate rose after a recent AGENTS.md change, prefer reverting or narrowing that change over adding another rule.
12. Commit with a behavioral message and push.
13. If no change is justified, make no file changes and say why in the log output.

Constraints:
- One batch, one decision. Do not spawn more agents.
- Do not edit for casual profanity, slurs used as examples, or frustration about an external system.
- Keep changes short and reversible.
- Do not use generic trigger-language placeholders in skills. Use activation_signals.
"""


def invoke_reflector(events: list[dict]) -> int:
    prompt = build_prompt(events)
    LAST_PROMPT.parent.mkdir(parents=True, exist_ok=True)
    LAST_PROMPT.write_text(prompt)
    batch = {
        "ts": iso_now(),
        "event_count": len(events),
        "sessions": sorted({session_key(event) for event in events}),
        "dry_run": DRY_RUN,
    }
    append_json(BATCHES, batch)

    if DRY_RUN:
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
            "Bash(*frustration-stats.sh)",
            "Bash(*validate-skills.py)",
            "Bash(mkdir -p *)",
        ]
    )
    env = os.environ.copy()
    env["INTROSPECT_REFLECTOR"] = "1"
    runner, runner_path = select_reflector_runner()
    cmd = build_reflector_command(runner, runner_path, prompt, allowed_tools)
    log(f"invoking {runner} reflector for {len(events)} event(s)")
    notify("Introspect", f"{runner} reflector spawned for {len(events)} frustration event(s)")
    with LOG.open("a") as log_file:
        display_cmd = " ".join(shlex.quote(part) for part in cmd)
        display_cmd = display_cmd.replace(shlex.quote(prompt), "<batch-prompt>")
        log_file.write(f"{iso_now()} command: {display_cmd}\n")
        result = subprocess.run(
            cmd,
            cwd=REPO,
            env=env,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=REFLECTOR_TIMEOUT_SECONDS,
        )
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


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--kick", action="store_true")
    parser.add_argument("--scheduled", action="store_true")
    parser.add_argument("--nightly", action="store_true")
    args = parser.parse_args()

    if not acquire_lock():
        return 0

    if not args.nightly and DEBOUNCE_SECONDS > 0:
        log(f"debouncing for {DEBOUNCE_SECONDS:.1f}s")
        time.sleep(DEBOUNCE_SECONDS)

    events = take_queue()
    if not events:
        log("no queued frustration events")
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
