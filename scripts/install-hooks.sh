#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PROMPT="$REPO/AGENTS.md"
HOOK="$REPO/hooks/frustration-reflect.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP

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

install_link "$PROMPT" "$HOME/.claude/CLAUDE.md"
install_link "$PROMPT" "$HOME/.codex/AGENTS.md"

python3 - "$HOOK" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import os
import sys
from pathlib import Path

hook_path = sys.argv[1]
settings_paths = [Path(path) for path in sys.argv[2:]]


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


def install(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = load_json(path)
    groups = data.setdefault("hooks", {}).setdefault("UserPromptSubmit", [])
    if not isinstance(groups, list):
        raise SystemExit(f"{path}: hooks.UserPromptSubmit must be a list")

    kept_groups = []
    for group in groups:
        if not isinstance(group, dict):
            kept_groups.append(group)
            continue
        hooks = group.get("hooks")
        if not isinstance(hooks, list):
            kept_groups.append(group)
            continue
        kept_hooks = [hook for hook in hooks if not is_frustration_hook(hook)]
        if kept_hooks:
            new_group = dict(group)
            new_group["hooks"] = kept_hooks
            kept_groups.append(new_group)

    kept_groups.append(
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
    data["hooks"]["UserPromptSubmit"] = kept_groups

    old = path.read_text() if path.exists() else None
    new = json.dumps(data, indent=2, sort_keys=False) + "\n"
    if old == new:
        print(f"ok: {path}")
        return
    if old is not None:
        backup = path.with_name(f"{path.name}.bak.{os.environ.get('STAMP', '')}")
        if str(backup).endswith(".bak."):
            backup = path.with_suffix(path.suffix + ".bak")
        backup.write_text(old)
        print(f"backed up: {path} -> {backup}")
    path.write_text(new)
    print(f"installed hook: {path}")


for settings_path in settings_paths:
    install(settings_path)
PY

echo "installed self-healing-agent-md hooks from $REPO"
