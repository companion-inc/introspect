#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROMPT="$REPO/AGENTS.md"
HOOK="$REPO/hooks/frustration-reflect.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP
MODE="${1:-install}"

usage() {
  cat <<EOF
Usage: $0 [install|--uninstall]

install      Link the global prompt and install Claude/Codex UserPromptSubmit hooks.
--uninstall  Remove this repo's prompt links and frustration hooks.
EOF
}

case "$MODE" in
  install|"")
    MODE="install"
    ;;
  --uninstall|uninstall)
    MODE="uninstall"
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

if [[ ! -f "$PROMPT" ]]; then
  echo "missing prompt: $PROMPT" >&2
  exit 1
fi

if [[ ! -f "$HOOK" ]]; then
  echo "missing hook: $HOOK" >&2
  exit 1
fi

chmod +x "$HOOK" "$REPO/hooks/frustration-worker.py" "$REPO/hooks/frustration-stats.sh" "$REPO/hooks/launch-reflector.sh"

install_link() {
  local target="$1"
  local link="$2"
  mkdir -p "$(dirname "$link")"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    echo "ok: $link -> $target"
    return
  fi
  if [[ -e "$link" || -L "$link" ]]; then
    mv "$link" "$link.bak.$STAMP"
    echo "backed up: $link -> $link.bak.$STAMP"
  fi
  ln -s "$target" "$link"
  echo "linked: $link -> $target"
}

uninstall_link() {
  local target="$1"
  local link="$2"
  if [[ -L "$link" && "$(readlink "$link")" == "$target" ]]; then
    rm "$link"
    echo "removed link: $link"
  else
    echo "skip: $link is not a link to $target"
  fi
}

if [[ "$MODE" == "install" ]]; then
  install_link "$PROMPT" "$HOME/.claude/CLAUDE.md"
  install_link "$PROMPT" "$HOME/.codex/AGENTS.md"
else
  uninstall_link "$PROMPT" "$HOME/.claude/CLAUDE.md"
  uninstall_link "$PROMPT" "$HOME/.codex/AGENTS.md"
fi

python3 - "$MODE" "$HOOK" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import os
import sys
from pathlib import Path

mode = sys.argv[1]
hook_path = sys.argv[2]
settings_paths = [Path(path) for path in sys.argv[3:]]


def load_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open() as f:
        data = json.load(f)
    if not isinstance(data, dict):
        raise SystemExit(f"{path} must contain a JSON object")
    return data


def is_frustration_hook(hook: object) -> bool:
    if not isinstance(hook, dict):
        return False
    command = hook.get("command")
    return isinstance(command, str) and command.endswith("/hooks/frustration-reflect.sh")


def write_if_changed(path: Path, data: dict) -> bool:
    old = path.read_text() if path.exists() else None
    new = json.dumps(data, indent=2, sort_keys=False) + "\n"
    if old == new:
        print(f"ok: {path}")
        return False
    if old is not None:
        backup = path.with_name(f"{path.name}.bak.{os.environ.get('STAMP', '')}")
        if str(backup).endswith(".bak."):
            backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(old)
        print(f"backed up: {path} -> {backup}")
    path.write_text(new)
    return True


def remove_frustration_hooks(path: Path) -> tuple[dict, int]:
    data = load_json(path)
    hook_root = data.setdefault("hooks", {})
    groups = hook_root.setdefault("UserPromptSubmit", [])
    if not isinstance(groups, list):
        raise SystemExit(f"{path}: hooks.UserPromptSubmit must be a list")

    kept_groups = []
    removed = 0
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        hooks = group.get("hooks")
        if not isinstance(hooks, list):
            kept_groups.append(group)
            continue
        kept_hooks = []
        for hook in hooks:
            if is_frustration_hook(hook):
                removed += 1
            else:
                kept_hooks.append(hook)
        if kept_hooks:
            new_group = dict(group)
            new_group["hooks"] = kept_hooks
            kept_groups.append(new_group)
    hook_root["UserPromptSubmit"] = kept_groups
    return data, removed


def install(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data, _removed = remove_frustration_hooks(path)
    groups = data["hooks"]["UserPromptSubmit"]

    groups.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": hook_path,
                    "timeout": 10,
                }
            ]
        }
    )
    changed = write_if_changed(path, data)
    if changed:
        print(f"installed hook: {path}")


def uninstall(path: Path) -> None:
    if not path.exists():
        print(f"skip: {path} does not exist")
        return
    data, removed = remove_frustration_hooks(path)
    changed = write_if_changed(path, data)
    if removed and changed:
        print(f"removed {removed} hook(s): {path}")
    elif removed:
        print(f"removed {removed} hook(s): {path}")
    else:
        print(f"skip: no frustration hook in {path}")


for settings_path in settings_paths:
    if mode == "install":
        install(settings_path)
    else:
        uninstall(settings_path)
PY

if [[ "$MODE" == "install" ]]; then
  echo "installed self-healing-agent-md hooks from $REPO"
else
  echo "uninstalled self-healing-agent-md hooks from $REPO"
fi
