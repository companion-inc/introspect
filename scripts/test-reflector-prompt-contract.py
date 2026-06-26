#!/usr/bin/python3
"""Regression checks for the reflector's layer-selection prompt."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
WORKER = REPO / "hooks" / "trigger-worker.py"


def fail(message: str) -> None:
    raise SystemExit(f"test-reflector-prompt-contract: {message}")


def load_worker(home: Path, runtime: Path, extra_env: dict[str, str] | None = None):
    agents_home = home.parent / ".agents"
    env = {
        "INTROSPECT_REPO": str(runtime),
        "AGENTS_HOME": str(agents_home),
        "INTROSPECT_HOME": str(home),
        "INTROSPECT_PROMPT": str(home / "AGENTS.md"),
        "INTROSPECT_SKILLS_DIR": str(runtime / "skills"),
        "INTROSPECT_USER_SKILLS_DIR": str(home / "skills"),
        "INTROSPECT_FEEDBACK_DIR": str(home / "feedback"),
    }
    if extra_env:
        env.update(extra_env)
    os.environ.update(env)
    spec = importlib.util.spec_from_file_location("introspect_trigger_worker_contract", WORKER)
    if spec is None or spec.loader is None:
        fail(f"cannot load {WORKER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-reflector-contract-") as tmp:
        base = Path(tmp)
        agents_home = base / ".agents"
        home = base / ".introspect"
        runtime = base / "introspect-runtime"
        project = base / "project"
        (runtime / "skills").mkdir(parents=True)
        (home / "skills").mkdir(parents=True)
        (home / "feedback").mkdir(parents=True)
        (home / "AGENTS.md").write_text("# test\n", encoding="utf-8")
        agents_home.mkdir()
        project.mkdir()

        worker = load_worker(home=home, runtime=runtime)
        event = {
            "event_id": "evt",
            "ts": "2026-06-20T00:00:00+00:00",
            "source": "test",
            "cwd": str(project),
            "transcript_path": str(base / "rollout.jsonl"),
            "transcript_line": 7,
            "message_locator": f"{base / 'rollout.jsonl'}:7",
            "snippet": "fix it",
        }
        prompt = worker.build_prompt([event])
        prompt_path = worker.PROMPT_PATH
        worker_home = worker.INTROSPECT_HOME
        runtime_path = worker.REPO
        built_in_skills = worker.SKILLS_DIR
        user_skills = worker.USER_SKILLS_DIR

        required = [
            "Live global prompt:",
            "Apply mode: proposal",
            f"- {prompt_path}",
            "Introspect home Git repo:",
            f"- {worker_home}",
            "Built-in skills directory:",
            f"- {built_in_skills}",
            "User skill directory:",
            f"- {user_skills}",
            f"Run /usr/bin/python3 {runtime_path}/hooks/trigger-stats.sh",
            f"Edit the live global prompt at {prompt_path}",
            f"do not edit Introspect runtime files under {runtime_path}",
            "The target repo is the event cwd or the project proven by the transcript",
            "Proposal mode is enabled",
            "write a proposal",
            "Export each skill to one native global namespace only",
            "Commit in Introspect home",
        ]
        for needle in required:
            if needle not in prompt:
                fail(f"missing prompt contract: {needle}")

        roots = worker.surface_scan_roots([event])
        if runtime.resolve() in roots:
            fail("CLI runtime must not be snapshotted as an editable surface root for unrelated projects")
        if project.resolve() in roots:
            fail("target project repo must not be snapshotted by the background reflector")
        for expected in [home.resolve()]:
            if expected not in roots:
                fail(f"missing surface root: {expected}")

        command = worker.build_reflector_command("codex", "/usr/local/bin/codex", "prompt", "Read")
        try:
            cwd_index = command.index("-C") + 1
        except ValueError:
            fail("codex reflector command is missing -C")
        if command[cwd_index] != str(worker.REFLECTOR_CWD):
            fail(f"codex reflector cwd is {command[cwd_index]}, expected {worker.REFLECTOR_CWD}")
        if "prompt" in command:
            fail("codex reflector command leaked the prompt through argv")
        if "-" not in command:
            fail("codex reflector command should read the prompt from stdin")
        if 'sandbox_mode="workspace-write"' not in command:
            fail(f"proposal command should stay workspace-write: {command}")

        auto_worker = load_worker(
            home=home,
            runtime=runtime,
            extra_env={"INTROSPECT_REFLECTOR_APPLY_MODE": "auto"},
        )
        auto_prompt = auto_worker.build_prompt([event])
        for needle in [
            "Apply mode: auto",
            "Auto-apply mode is enabled",
            "edit the target repo's AGENTS.md/CLAUDE.md directly",
        ]:
            if needle not in auto_prompt:
                fail(f"missing auto prompt contract: {needle}")
        auto_roots = auto_worker.surface_scan_roots([event])
        if project.resolve() not in auto_roots:
            fail("auto-apply mode must snapshot the target project repo")
        auto_command = auto_worker.build_reflector_command("codex", "/usr/local/bin/codex", "prompt", "Read")
        if 'sandbox_mode="danger-full-access"' not in auto_command:
            fail(f"auto command should use wider sandbox: {auto_command}")

        pid_file = base / "child.pid"
        child_script = (
            "import pathlib, subprocess, sys, time\n"
            "p = subprocess.Popen(['sleep', '60'])\n"
            "pathlib.Path(sys.argv[1]).write_text(str(p.pid))\n"
            "time.sleep(60)\n"
        )
        with open(os.devnull, "w") as devnull:
            try:
                worker.run_reflector_subprocess(
                    [sys.executable, "-c", child_script, str(pid_file)],
                    cwd=base,
                    env=os.environ.copy(),
                    input_text="",
                    log_file=devnull,
                    timeout=1,
                )
            except subprocess.TimeoutExpired:
                pass
            else:
                fail("timed reflector command unexpectedly completed")

        try:
            child_pid = int(pid_file.read_text())
        except Exception as exc:
            fail(f"child pid was not recorded: {exc!r}")
        for _ in range(30):
            if not process_alive(child_pid):
                break
            time.sleep(0.1)
        else:
            fail("timed-out reflector left a child process alive")

    print("test-reflector-prompt-contract: ok")


if __name__ == "__main__":
    main()
