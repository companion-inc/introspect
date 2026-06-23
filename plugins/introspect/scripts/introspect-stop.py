#!/usr/bin/env python3
"""Codex Stop hook adapter for Introspect."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from pathlib import Path


def load_payload() -> dict:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def first(payload: dict, *keys: str) -> str:
    for key in keys:
        value = payload.get(key)
        if value:
            return str(value)
    return ""


def executable(path: Path) -> bool:
    return path.is_file() and os.access(path, os.X_OK)


def codex_config_path() -> Path:
    configured = os.environ.get("CODEX_HOME")
    if configured:
        return Path(configured).expanduser() / "config.toml"
    return Path.home() / ".codex" / "config.toml"


def unquote_toml_string(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        return value[1:-1]
    return value


def marketplace_name_from_plugin_root(plugin_root: Path) -> str:
    parts = plugin_root.parts
    try:
        cache_index = parts.index("cache")
    except ValueError:
        return ""
    if len(parts) > cache_index + 1:
        return parts[cache_index + 1]
    return ""


def marketplace_source(name: str) -> Path | None:
    if not name:
        return None
    config = codex_config_path()
    try:
        lines = config.read_text().splitlines()
    except OSError:
        return None

    target_sections = {f"[marketplaces.{name}]", f'[marketplaces."{name}"]'}
    in_section = False
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            in_section = stripped in target_sections
            continue
        if not in_section or not stripped.startswith("source"):
            continue
        key, _, value = stripped.partition("=")
        if key.strip() != "source":
            continue
        source = unquote_toml_string(value)
        return Path(source).expanduser()
    return None


def find_introspect_cli() -> str | None:
    configured = os.environ.get("INTROSPECT_CLI")
    if configured and executable(Path(configured).expanduser()):
        return str(Path(configured).expanduser())

    found = shutil.which("introspect")
    if found:
        return found

    plugin_root = Path(os.environ.get("PLUGIN_ROOT", "")).expanduser()
    if plugin_root:
        for candidate in (
            plugin_root.parent.parent / "bin" / "introspect",
            plugin_root.parent.parent.parent / "bin" / "introspect",
        ):
            if executable(candidate):
                return str(candidate)
        source = marketplace_source(marketplace_name_from_plugin_root(plugin_root))
        if source:
            candidate = source / "bin" / "introspect"
            if executable(candidate):
                return str(candidate)
    return None


def main() -> int:
    payload = load_payload()
    cli = find_introspect_cli()
    if cli is None:
        print("Introspect CLI not found; run skipped.", file=sys.stderr)
        return 0

    cwd = first(payload, "cwd") or os.getcwd()
    transcript_path = first(payload, "transcript_path", "transcriptPath")
    session_id = first(payload, "session_id", "sessionId")
    generation_id = first(payload, "generation_id", "generationId", "id")

    command = [
        cli,
        "run",
        "--host",
        "codex",
        "--event",
        "stop",
        "--cwd",
        cwd,
        "--json",
    ]
    if transcript_path:
        command.extend(["--transcript-path", transcript_path])
    if session_id:
        command.extend(["--session-id", session_id])
    if generation_id:
        command.extend(["--generation-id", generation_id])

    env = os.environ.copy()
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    result = subprocess.run(
        command,
        cwd=cwd if os.path.isdir(cwd) else None,
        env=env,
        capture_output=True,
        text=True,
        timeout=25,
        check=False,
    )
    if result.returncode != 0:
        output = (result.stderr or result.stdout).strip()
        if output:
            print(output[:1000], file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
