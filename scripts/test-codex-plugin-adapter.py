#!/usr/bin/env python3
"""Regression checks for the Codex plugin Stop hook adapter."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HOOK = REPO / "plugins" / "introspect" / "scripts" / "introspect-stop.py"
CLI = REPO / "bin" / "introspect"


def fail(message: str) -> None:
    raise SystemExit(f"test-codex-plugin-adapter: {message}")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="introspect-plugin-") as tmp:
        base = Path(tmp)
        home = base / ".introspect"
        project = base / "project"
        transcript = base / "sessions" / "rollout-plugin.jsonl"
        project.mkdir()
        transcript.parent.mkdir(parents=True)
        transcript.write_text(
            '{"type":"session_meta","payload":{"id":"plugin-session","cwd":"'
            + str(project)
            + '"}}\n'
        )
        payload = {
            "cwd": str(project),
            "transcript_path": str(transcript),
            "session_id": "plugin-session",
            "generation_id": "plugin-generation",
        }
        env = os.environ.copy()
        codex_home = base / ".codex"
        codex_home.mkdir()
        (codex_home / "config.toml").write_text(
            '[marketplaces.introspect-local]\n'
            'source_type = "local"\n'
            f'source = "{REPO}"\n'
        )
        cached_plugin_root = (
            base
            / ".codex"
            / "plugins"
            / "cache"
            / "introspect-local"
            / "introspect"
            / "0.1.0"
        )
        cached_plugin_root.mkdir(parents=True)
        env.update(
            {
                "HOME": str(base),
                "INTROSPECT_HOME": str(home),
                "CODEX_HOME": str(codex_home),
                "PLUGIN_ROOT": str(cached_plugin_root),
                "PYTHONDONTWRITEBYTECODE": "1",
            }
        )
        result = subprocess.run(
            ["/usr/bin/python3", str(HOOK)],
            input=json.dumps(payload),
            cwd=project,
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            fail(result.stderr or result.stdout)
        state_path = home / "introspect" / "codex" / "state.json"
        if not state_path.is_file():
            fail("hook did not create cadence state")
        state = json.loads(state_path.read_text())
        if state.get("host") != "codex":
            fail(f"unexpected state: {state}")

    print("test-codex-plugin-adapter: ok")


if __name__ == "__main__":
    main()
