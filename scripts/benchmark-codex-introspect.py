#!/usr/bin/python3
"""Run Codex CLI A/B tasks with and without Introspect installed.

The harness keeps auth constant and changes only the run home:

- baseline arm: copied Codex auth, no Introspect prompt link, no Introspect hook
- introspect arm: copied Codex auth, Introspect installed into the temp home

Task manifests are JSONL objects. Minimal shape:

{
  "id": "fix-foo",
  "repo": "/absolute/path/to/git/repo",
  "turns": [
    {"prompt": "Fix the bug. Run tests."},
    {"prompt": "You missed the edge case. Read the failing test and continue."},
    {"new_thread": true, "prompt": "Run the same workflow on the next file."}
  ],
  "score_command": "pytest -q"
}
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[1]
INSTALL_HOOKS = REPO / "scripts" / "install-hooks.sh"


def fail(message: str) -> None:
    raise SystemExit(f"benchmark-codex-introspect: {message}")


def safe_id(value: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", value.strip())
    cleaned = cleaned.strip(".-")
    return cleaned or "task"


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for line_no, line in enumerate(path.read_text().splitlines(), start=1):
        if not line.strip():
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as exc:
            fail(f"{path}:{line_no}: invalid JSON: {exc}")
        if not isinstance(row, dict):
            fail(f"{path}:{line_no}: expected JSON object")
        rows.append(row)
    return rows


def write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def append_jsonl(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(payload, ensure_ascii=False, sort_keys=True) + "\n")


def run_command(
    cmd: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    timeout: int,
    stdout_path: Path,
    stderr_path: Path,
    input_text: str | None = None,
) -> dict[str, Any]:
    stdout_path.parent.mkdir(parents=True, exist_ok=True)
    stderr_path.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    with stdout_path.open("w") as stdout, stderr_path.open("w") as stderr:
        try:
            proc = subprocess.run(
                cmd,
                cwd=cwd,
                env=env,
                input=input_text,
                text=True,
                stdout=stdout,
                stderr=stderr,
                timeout=timeout,
                check=False,
            )
            timed_out = False
            returncode = proc.returncode
        except subprocess.TimeoutExpired:
            timed_out = True
            returncode = 124
    return {
        "cmd": cmd,
        "cwd": str(cwd),
        "duration_seconds": round(time.monotonic() - started, 3),
        "returncode": returncode,
        "timed_out": timed_out,
        "stdout": str(stdout_path),
        "stderr": str(stderr_path),
    }


def parse_json_events(path: Path) -> dict[str, Any]:
    events: list[dict[str, Any]] = []
    thread_id = ""
    usage: dict[str, Any] = {}
    final_message = ""
    if not path.exists():
        return {"events": events, "thread_id": thread_id, "usage": usage, "final_message": final_message}
    for line in path.read_text(errors="replace").splitlines():
        try:
            row = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(row, dict):
            continue
        events.append(row)
        if row.get("type") == "thread.started":
            thread_id = str(row.get("thread_id") or thread_id)
        if row.get("type") == "turn.completed" and isinstance(row.get("usage"), dict):
            usage = row["usage"]
        item = row.get("item")
        if isinstance(item, dict) and item.get("type") == "agent_message":
            final_message = str(item.get("text") or final_message)
    return {
        "events": events,
        "thread_id": thread_id,
        "usage": usage,
        "final_message": final_message,
    }


def read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text())
    except Exception:
        return {}
    return data if isinstance(data, dict) else {}


def copy_codex_auth(source: Path, target: Path, *, copy_config: bool) -> list[str]:
    target.mkdir(parents=True, exist_ok=True)
    copied: list[str] = []
    required = source / "auth.json"
    if not required.is_file():
        fail(f"missing Codex auth file: {required}")
    for name in ("auth.json", "installation_id"):
        src = source / name
        if src.is_file():
            shutil.copy2(src, target / name)
            copied.append(name)
    if copy_config:
        src = source / "config.toml"
        if src.is_file():
            shutil.copy2(src, target / "config.toml")
            copied.append("config.toml")
    return copied


def prepare_workspace(task: dict[str, Any], workspace: Path) -> None:
    repo = task.get("repo")
    workspace.parent.mkdir(parents=True, exist_ok=True)
    if not repo:
        workspace.mkdir(parents=True, exist_ok=True)
    else:
        repo_path = Path(str(repo)).expanduser()
        if not repo_path.exists():
            fail(f"task {task.get('id')}: repo does not exist: {repo_path}")
        commit = str(task.get("commit") or "").strip()
        if (repo_path / ".git").exists():
            subprocess.run(
                ["git", "clone", "--no-hardlinks", str(repo_path), str(workspace)],
                cwd=workspace.parent,
                check=True,
                stdout=subprocess.DEVNULL,
            )
            if commit:
                subprocess.run(["git", "checkout", "--detach", commit], cwd=workspace, check=True)
        else:
            shutil.copytree(repo_path, workspace)
    write_task_files(task, workspace)
    run_setup_command(task, workspace)


def write_task_files(task: dict[str, Any], workspace: Path) -> None:
    files = task.get("files")
    if not isinstance(files, dict):
        return
    workspace.mkdir(parents=True, exist_ok=True)
    for raw_path, content in files.items():
        relative = Path(str(raw_path))
        if relative.is_absolute() or ".." in relative.parts:
            fail(f"task {task.get('id')}: invalid fixture path: {raw_path}")
        target = workspace / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, (dict, list)):
            target.write_text(json.dumps(content, indent=2, sort_keys=True) + "\n")
        else:
            target.write_text(str(content))


def run_setup_command(task: dict[str, Any], workspace: Path) -> None:
    command = task.get("setup_command")
    if not command:
        return
    result = subprocess.run(
        ["/bin/bash", "-lc", str(command)],
        cwd=workspace,
        text=True,
        capture_output=True,
        timeout=int(task.get("setup_timeout_seconds") or 120),
        check=False,
    )
    if result.returncode != 0:
        fail(
            f"task {task.get('id')}: setup_command failed with {result.returncode}\n"
            f"stdout:\n{result.stdout[-2000:]}\n"
            f"stderr:\n{result.stderr[-2000:]}"
        )


def install_introspect_home(case_home: Path, introspect_home: Path, args: argparse.Namespace) -> dict[str, Any]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(case_home),
            "CODEX_HOME": str(case_home / ".codex"),
            "INTROSPECT_HOME": str(introspect_home),
            "INTROSPECT_SKIP_LAUNCHD": "1",
            "INTROSPECT_SKIP_BACKFILL": "1",
            "INTROSPECT_TELEMETRY": "off",
            "INTROSPECT_NOTIFY": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    cmd = [
        str(INSTALL_HOOKS),
        "--home",
        str(introspect_home),
        "--agents-home",
        str(case_home / ".agents"),
        "--reflect-mode",
        args.reflect_mode,
        "--apply-mode",
        args.apply_mode,
        "--runner",
        "codex",
        "--telemetry",
        "off",
        "--no-backfill",
        "--wake-sensitivity",
        args.wake_sensitivity,
    ]
    if args.wake_threshold:
        cmd.extend(["--wake-threshold", args.wake_threshold])
    return run_command(
        cmd,
        cwd=REPO,
        env=env,
        timeout=120,
        stdout_path=introspect_home / "install.stdout.txt",
        stderr_path=introspect_home / "install.stderr.txt",
    )


def arm_env(
    case_home: Path,
    introspect_home: Path,
    arm_dir: Path,
    args: argparse.Namespace,
    task_env: dict[str, str] | None = None,
) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(case_home),
            "CODEX_HOME": str(case_home / ".codex"),
            "INTROSPECT_HOME": str(introspect_home),
            "INTROSPECT_FEEDBACK_DIR": str(introspect_home / "feedback"),
            "INTROSPECT_NOTIFY": "0",
            "PYTHONDONTWRITEBYTECODE": "1",
            "BENCH_ARM_DIR": str(arm_dir),
            "TRIGGER_DEBOUNCE_SECONDS": str(args.trigger_debounce_seconds),
            "TRIGGER_COOLDOWN_SECONDS": str(args.trigger_cooldown_seconds),
            "TRIGGER_SESSION_COOLDOWN_SECONDS": str(args.trigger_session_cooldown_seconds),
        }
    )
    if task_env:
        env.update({str(key): str(value) for key, value in task_env.items()})
    return env


def wait_for_introspect_idle(introspect_home: Path, timeout: float) -> dict[str, Any]:
    feedback = introspect_home / "feedback"
    queue = feedback / "trigger-queue.jsonl"
    lock = feedback / "reflector.lock"
    state_path = feedback / "reflector-state.json"
    started = time.monotonic()
    while True:
        queue_pending = queue.exists() and bool(queue.read_text(errors="replace").strip())
        lock_pending = lock.exists()
        state = read_json(state_path)
        invocation = state.get("last_invocation")
        status = invocation.get("status") if isinstance(invocation, dict) else ""
        running = status in {"starting", "running"}
        if not queue_pending and not lock_pending and not running:
            return {
                "idle": True,
                "duration_seconds": round(time.monotonic() - started, 3),
                "last_status": status or "",
            }
        if time.monotonic() - started >= timeout:
            return {
                "idle": False,
                "duration_seconds": round(time.monotonic() - started, 3),
                "queue_pending": queue_pending,
                "lock_pending": lock_pending,
                "last_status": status or "",
            }
        time.sleep(0.5)


def codex_base_cmd(args: argparse.Namespace, *, with_introspect: bool) -> list[str]:
    cmd = ["codex", "exec", "--json", "--skip-git-repo-check"]
    if args.model:
        cmd.extend(["--model", args.model])
    if args.bypass_sandbox:
        cmd.append("--dangerously-bypass-approvals-and-sandbox")
    else:
        cmd.extend(["--sandbox", args.sandbox])
    if with_introspect:
        cmd.append("--dangerously-bypass-hook-trust")
    for extra in args.codex_arg:
        cmd.append(extra)
    return cmd


def run_turns(
    task: dict[str, Any],
    *,
    arm: str,
    with_introspect: bool,
    workspace: Path,
    case_home: Path,
    introspect_home: Path,
    arm_dir: Path,
    args: argparse.Namespace,
) -> dict[str, Any]:
    turns = task.get("turns")
    if not isinstance(turns, list) or not turns:
        prompt = task.get("prompt")
        if not isinstance(prompt, str) or not prompt.strip():
            fail(f"task {task.get('id')}: provide prompt or turns")
        turns = [{"prompt": prompt}]
    env = arm_env(case_home, introspect_home, arm_dir, args, task.get("env") if isinstance(task.get("env"), dict) else None)
    thread_id = ""
    turn_results: list[dict[str, Any]] = []
    usage_totals: dict[str, int] = {}

    for index, turn in enumerate(turns, start=1):
        if not isinstance(turn, dict):
            fail(f"task {task.get('id')}: turn {index} is not an object")
        prompt = str(turn.get("prompt") or "").strip()
        if not prompt:
            fail(f"task {task.get('id')}: turn {index} has empty prompt")
        last_message = arm_dir / f"turn-{index:02d}.last-message.txt"
        stdout = arm_dir / f"turn-{index:02d}.stdout.jsonl"
        stderr = arm_dir / f"turn-{index:02d}.stderr.txt"
        start_new_thread = index == 1 or bool(turn.get("new_thread"))
        if start_new_thread:
            cmd = codex_base_cmd(args, with_introspect=with_introspect)
            cmd.extend(["-C", str(workspace), "-o", str(last_message), "-"])
        else:
            if not thread_id:
                fail(f"task {task.get('id')} arm {arm}: cannot resume without thread_id")
            cmd = codex_base_cmd(args, with_introspect=with_introspect)
            cmd = cmd[:2] + ["resume"] + cmd[2:]
            cmd.extend(["-o", str(last_message), thread_id, "-"])
        if args.dry_run:
            dry_thread_id = thread_id or f"dry-run-{safe_id(str(task.get('id') or 'task'))}-{arm}"
            result = {
                "cmd": cmd,
                "cwd": str(workspace),
                "returncode": 0,
                "timed_out": False,
                "dry_run": True,
                "stdout": str(stdout),
                "stderr": str(stderr),
            }
            stdout.write_text(
                json.dumps({"type": "thread.started", "thread_id": dry_thread_id}) + "\n"
                + json.dumps({"type": "dry_run", "cmd": cmd}) + "\n"
            )
            stderr.write_text("")
        else:
            result = run_command(
                cmd,
                cwd=workspace,
                env=env,
                timeout=int(turn.get("timeout_seconds") or task.get("timeout_seconds") or args.turn_timeout),
                stdout_path=stdout,
                stderr_path=stderr,
                input_text=prompt,
            )
        parsed = parse_json_events(stdout)
        if parsed["thread_id"]:
            thread_id = parsed["thread_id"]
        usage = parsed.get("usage") or {}
        if isinstance(usage, dict):
            for key, value in usage.items():
                if isinstance(value, int):
                    usage_totals[key] = usage_totals.get(key, 0) + value
        turn_results.append(
            {
                "index": index,
                "returncode": result["returncode"],
                "timed_out": result["timed_out"],
                "new_thread": start_new_thread,
                "thread_id": thread_id,
                "usage": usage,
                "final_message_path": str(last_message),
                "stdout": result["stdout"],
                "stderr": result["stderr"],
            }
        )
        if result["returncode"] != 0:
            break
        if with_introspect and index < len(turns) and args.introspect_wait_timeout > 0:
            turn_results[-1]["introspect_wait"] = wait_for_introspect_idle(
                introspect_home,
                timeout=float(args.introspect_wait_timeout),
            )
    return {"turns": turn_results, "thread_id": thread_id, "usage_total": usage_totals}


def run_score(task: dict[str, Any], *, workspace: Path, arm_dir: Path, env: dict[str, str], args: argparse.Namespace) -> dict[str, Any]:
    command = task.get("score_command")
    if not command:
        return {"returncode": 0, "skipped": True, "passed": True}
    score_env = env.copy()
    score_env.update({"TASK_WORKSPACE": str(workspace), "TASK_OUTPUT_DIR": str(arm_dir)})
    stdout = arm_dir / "score.stdout.txt"
    stderr = arm_dir / "score.stderr.txt"
    if args.dry_run:
        stdout.write_text(f"dry-run score_command: {command}\n")
        stderr.write_text("")
        return {"returncode": 0, "skipped": False, "passed": True, "dry_run": True, "stdout": str(stdout), "stderr": str(stderr)}
    result = run_command(
        ["/bin/bash", "-lc", str(command)],
        cwd=workspace,
        env=score_env,
        timeout=int(task.get("score_timeout_seconds") or args.score_timeout),
        stdout_path=stdout,
        stderr_path=stderr,
    )
    passed_codes = task.get("success_exit_codes")
    if not isinstance(passed_codes, list):
        passed_codes = [0]
    return {
        "returncode": result["returncode"],
        "timed_out": result["timed_out"],
        "passed": result["returncode"] in {int(code) for code in passed_codes},
        "stdout": result["stdout"],
        "stderr": result["stderr"],
    }


def git_diff_stat(workspace: Path) -> str:
    if not (workspace / ".git").exists():
        return ""
    result = subprocess.run(
        ["git", "diff", "--stat"],
        cwd=workspace,
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.strip()


def introspect_event_summary(introspect_home: Path) -> dict[str, int]:
    events_path = introspect_home / "feedback" / "events.jsonl"
    summary = {"events": 0, "triggered": 0, "review_triggered": 0}
    if not events_path.exists():
        return summary
    for line in events_path.read_text(errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict):
            continue
        summary["events"] += 1
        if event.get("triggered"):
            summary["triggered"] += 1
        if event.get("review_triggered"):
            summary["review_triggered"] += 1
    return summary


def run_arm(task: dict[str, Any], *, arm: str, run_dir: Path, args: argparse.Namespace) -> dict[str, Any]:
    task_id = safe_id(str(task.get("id") or "task"))
    with_introspect = arm == "codex_introspect"
    arm_dir = run_dir / "tasks" / task_id / arm
    case_home = arm_dir / "home"
    codex_home = case_home / ".codex"
    introspect_home = case_home / ".introspect"
    workspace = arm_dir / "workspace"
    if arm_dir.exists() and not args.keep_existing:
        shutil.rmtree(arm_dir)
    arm_dir.mkdir(parents=True, exist_ok=True)
    copied_auth = copy_codex_auth(Path(args.auth_source).expanduser(), codex_home, copy_config=args.copy_config)
    prepare_workspace(task, workspace)
    install_result: dict[str, Any] | None = None
    if with_introspect:
        install_result = install_introspect_home(case_home, introspect_home, args)
    setup_failed = bool(install_result and install_result.get("returncode") != 0)
    if setup_failed:
        run_result = {"turns": [], "thread_id": "", "usage_total": {}, "skipped": "introspect install failed"}
        score = {"returncode": 1, "skipped": True, "passed": False, "reason": "introspect install failed"}
    else:
        run_result = run_turns(
            task,
            arm=arm,
            with_introspect=with_introspect,
            workspace=workspace,
            case_home=case_home,
            introspect_home=introspect_home,
            arm_dir=arm_dir,
            args=args,
        )
        env = arm_env(case_home, introspect_home, arm_dir, args, task.get("env") if isinstance(task.get("env"), dict) else None)
        score = run_score(task, workspace=workspace, arm_dir=arm_dir, env=env, args=args)
    result = {
        "arm": arm,
        "task_id": task_id,
        "with_introspect": with_introspect,
        "workspace": str(workspace),
        "home": str(case_home),
        "codex_home": str(codex_home),
        "introspect_home": str(introspect_home),
        "copied_auth_files": copied_auth,
        "install": install_result,
        "setup_failed": setup_failed,
        "run": run_result,
        "score": score,
        "git_diff_stat": git_diff_stat(workspace),
        "introspect_events": introspect_event_summary(introspect_home),
    }
    write_json(arm_dir / "result.json", result)
    return result


def summarize(run_dir: Path, results: list[dict[str, Any]]) -> None:
    rows = []
    by_task: dict[str, dict[str, dict[str, Any]]] = {}
    for result in results:
        by_task.setdefault(result["task_id"], {})[result["arm"]] = result
    for task_id, arms in sorted(by_task.items()):
        baseline = arms.get("codex")
        introspect = arms.get("codex_introspect")
        rows.append(
            [
                task_id,
                "not run" if baseline is None else ("pass" if baseline["score"].get("passed") else "fail"),
                "not run" if introspect is None else ("pass" if introspect["score"].get("passed") else "fail"),
                str((baseline or {}).get("run", {}).get("usage_total", {}).get("input_tokens", "")),
                str((introspect or {}).get("run", {}).get("usage_total", {}).get("input_tokens", "")),
                str((introspect or {}).get("introspect_events", {}).get("events", "")),
                str((introspect or {}).get("introspect_events", {}).get("triggered", "")),
            ]
        )
    baseline_results = [result for result in results if result["arm"] == "codex"]
    intro_results = [result for result in results if result["arm"] == "codex_introspect"]
    passed_baseline = sum(1 for result in baseline_results if result["score"].get("passed"))
    passed_intro = sum(1 for result in intro_results if result["score"].get("passed"))
    task_count = len(by_task)
    baseline_summary = f"{passed_baseline}/{len(baseline_results)}" if baseline_results else "not run"
    intro_summary = f"{passed_intro}/{len(intro_results)}" if intro_results else "not run"
    lines = [
        "# Codex vs Codex+Introspect Benchmark",
        "",
        f"- tasks: {task_count}",
        f"- codex passed: {baseline_summary}",
        f"- codex_introspect passed: {intro_summary}",
        "",
        "| task | codex | codex_introspect | codex input tokens | introspect input tokens | hook events | hook wakes |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    for row in rows:
        lines.append("| " + " | ".join(row) + " |")
    (run_dir / "summary.md").write_text("\n".join(lines) + "\n")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Benchmark Codex CLI with and without Introspect hooks.")
    parser.add_argument("--tasks", required=True, help="JSONL task manifest.")
    parser.add_argument("--output-dir", default=str(REPO / ".benchmarks" / "codex-introspect"), help="Benchmark output root.")
    parser.add_argument("--auth-source", default="~/.codex", help="Codex home to copy auth from. Auth contents are never printed.")
    parser.add_argument("--copy-config", action="store_true", help="Also copy config.toml from auth source into each temp CODEX_HOME.")
    parser.add_argument("--model", default="", help="Optional Codex model id. Blank uses Codex default.")
    parser.add_argument("--arms", default="codex,codex_introspect", help="Comma-separated arms: codex,codex_introspect.")
    parser.add_argument("--reflect-mode", default="immediate", choices=["immediate", "nightly", "off"])
    parser.add_argument("--apply-mode", default="proposal", choices=["proposal", "auto", "never"])
    parser.add_argument("--wake-sensitivity", default="sensitive", choices=["quiet", "balanced", "sensitive", "custom"])
    parser.add_argument("--wake-threshold", default="")
    parser.add_argument("--sandbox", default="workspace-write", choices=["read-only", "workspace-write", "danger-full-access"])
    parser.add_argument("--bypass-sandbox", action="store_true", default=True, help="Use Codex's noninteractive full-access flag inside the temp workspace.")
    parser.add_argument("--no-bypass-sandbox", dest="bypass_sandbox", action="store_false")
    parser.add_argument("--codex-arg", action="append", default=[], help="Extra raw argument passed to codex exec and resume.")
    parser.add_argument("--turn-timeout", type=int, default=900)
    parser.add_argument("--score-timeout", type=int, default=300)
    parser.add_argument("--introspect-wait-timeout", type=int, default=180, help="Seconds to wait for Introspect queue/lock/state to go idle between turns.")
    parser.add_argument("--trigger-debounce-seconds", default="0", help="TRIGGER_DEBOUNCE_SECONDS for benchmark Introspect runs.")
    parser.add_argument("--trigger-cooldown-seconds", default="0", help="TRIGGER_COOLDOWN_SECONDS for benchmark Introspect runs.")
    parser.add_argument("--trigger-session-cooldown-seconds", default="0", help="TRIGGER_SESSION_COOLDOWN_SECONDS for benchmark Introspect runs.")
    parser.add_argument("--dry-run", action="store_true", help="Prepare homes/workspaces and write commands without invoking Codex.")
    parser.add_argument("--keep-existing", action="store_true", help="Do not delete existing arm directories before rerun.")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    tasks_path = Path(args.tasks).expanduser()
    if not tasks_path.is_file():
        fail(f"tasks file does not exist: {tasks_path}")
    if not INSTALL_HOOKS.is_file():
        fail(f"missing installer: {INSTALL_HOOKS}")
    tasks = read_jsonl(tasks_path)
    if not tasks:
        fail(f"no tasks in {tasks_path}")
    arms = [arm.strip() for arm in args.arms.split(",") if arm.strip()]
    allowed = {"codex", "codex_introspect"}
    invalid = [arm for arm in arms if arm not in allowed]
    if invalid:
        fail(f"invalid arm(s): {', '.join(invalid)}")
    run_dir = Path(args.output_dir).expanduser() / utc_stamp()
    run_dir.mkdir(parents=True, exist_ok=True)
    metadata = {
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "tasks": str(tasks_path),
        "arms": arms,
        "auth_source": str(Path(args.auth_source).expanduser()),
        "auth_files_copied": ["auth.json", "installation_id"] + (["config.toml"] if args.copy_config else []),
        "model": args.model or "codex default",
        "dry_run": args.dry_run,
    }
    write_json(run_dir / "metadata.json", metadata)
    results: list[dict[str, Any]] = []
    for task in tasks:
        for arm in arms:
            result = run_arm(task, arm=arm, run_dir=run_dir, args=args)
            results.append(result)
            append_jsonl(run_dir / "results.jsonl", result)
            status = "pass" if result["score"].get("passed") else "fail"
            print(f"{result['task_id']} {arm}: {status} -> {result['workspace']}")
    summarize(run_dir, results)
    print(f"summary: {run_dir / 'summary.md'}")


if __name__ == "__main__":
    main()
