#!/usr/bin/env bash
set -euo pipefail

MODE="sync"
AGENTS_HOME_DIR="${AGENTS_HOME:-$HOME/.agents}"
INTROSPECT_HOME_DIR="${INTROSPECT_HOME:-$HOME/.introspect}"
USER_SKILLS_DIR="${INTROSPECT_USER_SKILLS_DIR:-$INTROSPECT_HOME_DIR/skills}"
SETUP_PYTHON="${INTROSPECT_SETUP_PYTHON:-/usr/bin/python3}"

usage() {
  cat <<EOF
Usage: $0 [--unlink] [--home PATH] [--user-skills PATH]

Sync Introspect user skill folders into one agent-native global skill directory
per skill. OpenCode loads ~/.agents/skills, ~/.claude/skills, and
~/.config/opencode/skills, so duplicate skill names across those roots are not
safe.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unlink)
      MODE="unlink"
      shift
      ;;
    --home|--introspect-home)
      INTROSPECT_HOME_DIR="${2:-}"
      shift 2
      ;;
    --user-skills)
      USER_SKILLS_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

expand_path() {
  "$SETUP_PYTHON" - "$1" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

INTROSPECT_HOME_DIR="$(expand_path "$INTROSPECT_HOME_DIR")"
USER_SKILLS_DIR="$(expand_path "$USER_SKILLS_DIR")"
if [[ "$MODE" != "unlink" ]]; then
  mkdir -p "$USER_SKILLS_DIR"
fi

"$SETUP_PYTHON" - "$MODE" "$USER_SKILLS_DIR" "$HOME" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

mode = sys.argv[1]
source_root = Path(sys.argv[2]).expanduser().resolve()
home = Path(sys.argv[3]).expanduser().resolve()

target_roots = {
    "agents": home / ".agents" / "skills",
    "claude": home / ".claude" / "skills",
    "opencode": home / ".config" / "opencode" / "skills",
}
cleanup_roots = list(target_roots.values())
export_roots = target_roots


def echo(message: str) -> None:
    print(message)


def warn(message: str) -> None:
    print(message, file=sys.stderr)


def remove_managed_links(target_root: Path) -> None:
    if not target_root.is_dir():
        return
    for target in target_root.iterdir():
        if not target.is_symlink():
            continue
        try:
            resolved = target.resolve(strict=False)
        except OSError:
            continue
        if str(resolved).startswith(str(source_root) + os.sep):
            target.unlink()
            echo(f"removed skill link: {target}")


def frontmatter(path: Path) -> dict[str, object]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return {}
    if not lines or lines[0].strip() != "---":
        return {}

    fields: dict[str, object] = {}
    current_key: str | None = None
    current_list: list[str] | None = None
    for line in lines[1:]:
        stripped = line.strip()
        if stripped == "---":
            break
        if not stripped or stripped.startswith("#"):
            continue
        if current_list is not None and stripped.startswith("- "):
            current_list.append(stripped[2:].strip().strip("'\""))
            continue
        match = re.match(r"^([A-Za-z0-9_-]+):\s*(.*)$", line)
        if not match:
            continue
        key = match.group(1).strip().replace("-", "_")
        raw = match.group(2).strip()
        current_key = key
        if raw == "":
            current_list = []
            fields[key] = current_list
            continue
        current_list = None
        if raw.startswith("[") and raw.endswith("]"):
            values = [item.strip().strip("'\"") for item in raw[1:-1].split(",") if item.strip()]
            fields[key] = values
        else:
            fields[key] = raw.strip("'\"")
    return fields


def normalized_tokens(value: object) -> set[str]:
    values: list[str]
    if isinstance(value, list):
        values = [str(item) for item in value]
    elif isinstance(value, str):
        values = re.split(r"[,/ ]+", value)
    else:
        values = []
    return {item.strip().lower() for item in values if item.strip()}


def target_for_skill(skill_md: Path) -> str:
    fields = frontmatter(skill_md)
    tokens = normalized_tokens(fields.get("introspect_targets"))
    if not tokens:
        tokens = normalized_tokens(fields.get("introspect_target"))
    if not tokens:
        tokens = normalized_tokens(fields.get("compatibility"))

    if tokens & {"claude", "claude-code", "anthropic"}:
        return "claude"
    if tokens & {"opencode", "open-code"}:
        return "opencode"
    if tokens & {"codex", "openai", "agents", "agent", "agent-compatible"}:
        return "agents"
    if tokens & {"all", "universal", "cross-agent", "crossagent"}:
        warn(
            f"warn: {skill_md} requested a universal export; using ~/.agents/skills "
            "to avoid duplicate OpenCode skill names"
        )
    return "agents"


def skill_dirs() -> list[Path]:
    if not source_root.is_dir():
        return []
    return sorted(
        path for path in source_root.iterdir()
        if path.is_dir() and (path / "SKILL.md").is_file()
    )


def existing_duplicate_locations(slug: str, selected_root: Path) -> list[Path]:
    locations: list[Path] = []
    for root in export_roots.values():
        candidate = root / slug
        if root == selected_root or not candidate.exists():
            continue
        try:
            resolved = candidate.resolve(strict=False)
        except OSError:
            resolved = candidate
        if str(resolved).startswith(str(source_root) + os.sep):
            continue
        locations.append(candidate)
    return locations


for root in cleanup_roots:
    remove_managed_links(root)

if mode == "unlink":
    raise SystemExit(0)

for root in export_roots.values():
    root.mkdir(parents=True, exist_ok=True)

for skill_dir in skill_dirs():
    skill_md = skill_dir / "SKILL.md"
    slug = skill_dir.name
    target_key = target_for_skill(skill_md)
    target_root = export_roots[target_key]
    target = target_root / slug

    duplicates = existing_duplicate_locations(slug, target_root)
    if duplicates:
        warn(
            "warn: OpenCode-visible skill name collision for "
            f"{slug}: " + ", ".join(str(path) for path in duplicates)
        )

    if target.exists() or target.is_symlink():
        if target.is_symlink() and target.resolve(strict=False) == skill_dir.resolve(strict=False):
            echo(f"ok: {target} -> {skill_dir}")
            continue
        warn(f"skip: {target} already exists and is not an Introspect skill link")
        continue

    target.symlink_to(skill_dir)
    echo(f"linked skill: {target} -> {skill_dir}")
PY
