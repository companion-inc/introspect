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
import random
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


REPO = Path(os.path.expanduser(os.environ.get("AGENTS_MD_REPO", "~/Projects/agent-loop")))
SKILLS_DIR = Path(os.path.expanduser(os.environ.get("AGENTS_MD_SKILLS_DIR", str(REPO / "skills"))))
FEEDBACK_DIR = Path(
    os.path.expanduser(os.environ.get("AGENTS_MD_FEEDBACK_DIR", str(REPO / "feedback")))
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
DRY_RUN = os.environ.get("FRUSTRATION_REFLECTOR_DRY_RUN") == "1"
DISABLE_SCHEDULE = os.environ.get("FRUSTRATION_DISABLE_SCHEDULE") == "1"
REFLECTOR_RUNNER = os.environ.get("AGENT_LOOP_REFLECTOR_RUNNER", "auto").strip().lower() or "auto"


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="seconds")


def parse_ts(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value)
    except ValueError:
        return None


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
    if os.environ.get("AGENT_LOOP_NOTIFY") == "0" or os.environ.get("AGENTS_MD_NOTIFY") == "0":
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


def select_reflector_runner() -> tuple[str, str]:
    runners = available_reflector_runners()
    if REFLECTOR_RUNNER == "auto":
        if not runners:
            raise RuntimeError("no reflector runner found; install claude or codex")
        names = sorted(runners)
        name = random.choice(names)
        return name, runners[name]
    if REFLECTOR_RUNNER not in {"claude", "codex"}:
        raise RuntimeError(f"invalid AGENT_LOOP_REFLECTOR_RUNNER={REFLECTOR_RUNNER!r}")
    path = runners.get(REFLECTOR_RUNNER)
    if not path:
        raise RuntimeError(f"requested reflector runner {REFLECTOR_RUNNER!r} is not on PATH")
    return REFLECTOR_RUNNER, path


def build_reflector_command(runner: str, runner_path: str, prompt: str, allowed_tools: str) -> list[str]:
    if runner == "claude":
        return [runner_path, "-p", prompt, "--allowedTools", allowed_tools]
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
    env["AGENTS_MD_REFLECTOR"] = "1"
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

    return f"""You are the agent-loop frustration reflector.

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
3. Classify the change target as exactly one of: no_change, core_prompt, skill_new, skill_update, skill_prune.
4. Use core_prompt only for an always-loaded invariant that should apply across nearly every task. Before editing AGENTS.md, read skills/agent-md-creator/SKILL.md.
5. Use skill_new or skill_update for scoped workflows, domains, repeated failure shapes, or instructions that should load only in relevant situations. Use skill_prune for stale, duplicated, overbroad, unsupported, or harmful skills. Before any skill operation, read skills/skill-creator/SKILL.md, its source map, the skills index, and the closest existing skill. Prefer updating or pruning a close skill over creating a duplicate.
6. For skill changes, write or edit a self-contained skills/<slug>/SKILL.md in this repo, update skills/index.json, and run AGENTS_MD_SKILLS_DIR={SKILLS_DIR} {REPO}/scripts/validate-skills.py. For skill_prune, prefer marking status deprecated or narrowing activation before deleting files.
7. If the frustration rate rose after a recent AGENTS.md change, prefer reverting or narrowing that change over adding another rule.
8. Commit with a behavioral message and push.
9. If no change is justified, make no file changes and say why in the log output.

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
            "Bash(mkdir -p skills/*)",
        ]
    )
    env = os.environ.copy()
    env["AGENTS_MD_REFLECTOR"] = "1"
    runner, runner_path = select_reflector_runner()
    cmd = build_reflector_command(runner, runner_path, prompt, allowed_tools)
    log(f"invoking {runner} reflector for {len(events)} event(s)")
    notify("agent-loop", f"{runner} reflector spawned for {len(events)} frustration event(s)")
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
            timeout=1800,
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
