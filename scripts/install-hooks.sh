#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="$REPO/hooks/frustration-reflect.sh"
WORKER="$REPO/hooks/frustration-worker.py"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP

MODE="install"
PROMPT=""
SKILLS_DIR=""
FEEDBACK_DIR=""
REFLECT_MODE="immediate"
NIGHTLY_HOUR=3
NIGHTLY_MINUTE=0
REFLECTOR_RUNNER="auto"
LAUNCH_LABEL="ai.companion.introspect.reflector"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"

usage() {
  cat <<EOF
Usage: $0 [--uninstall] [--prompt PATH] [--skills PATH] [--feedback-dir PATH] [--reflect-mode immediate|nightly|off] [--nightly-hour H] [--nightly-minute M] [--runner auto|claude|codex]

install          Link this repo's prompt and configure Claude/Codex hooks.
--uninstall      Remove this repo's prompt links, hooks, and reflector LaunchAgents.
--reflect-mode   immediate kicks the locked worker after frustration; nightly queues for the LaunchAgent; off removes hooks but keeps prompt links.
--runner         Reflector runner. auto picks claude/codex from PATH, randomly if both exist.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    install)
      MODE="install"
      shift
      ;;
    --uninstall|uninstall)
      MODE="uninstall"
      shift
      ;;
    --prompt)
      PROMPT="${2:-}"
      shift 2
      ;;
    --skills)
      SKILLS_DIR="${2:-}"
      shift 2
      ;;
    --feedback-dir)
      FEEDBACK_DIR="${2:-}"
      shift 2
      ;;
    --reflect-mode|--mode)
      REFLECT_MODE="${2:-}"
      shift
      shift
      ;;
    --nightly)
      REFLECT_MODE="nightly"
      shift
      ;;
    --no-nightly)
      if [[ "$REFLECT_MODE" == "nightly" ]]; then
        REFLECT_MODE="immediate"
      fi
      shift
      ;;
    --nightly-hour)
      NIGHTLY_HOUR="${2:-}"
      shift 2
      ;;
    --nightly-minute)
      NIGHTLY_MINUTE="${2:-}"
      shift 2
      ;;
    --runner)
      REFLECTOR_RUNNER="${2:-}"
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
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(os.path.expanduser(sys.argv[1])))
PY
}

quote() {
  printf "%q" "$1"
}

if [[ -z "$PROMPT" ]]; then
  if [[ -f "$REPO/AGENTS.md" ]]; then
    PROMPT="$REPO/AGENTS.md"
  else
    echo "missing --prompt PATH" >&2
    exit 2
  fi
fi

PROMPT="$(expand_path "$PROMPT")"
if [[ -z "$SKILLS_DIR" ]]; then
  SKILLS_DIR="$REPO/skills"
fi
SKILLS_DIR="$(expand_path "$SKILLS_DIR")"
if [[ -z "$FEEDBACK_DIR" ]]; then
  FEEDBACK_DIR="$REPO/feedback"
fi
FEEDBACK_DIR="$(expand_path "$FEEDBACK_DIR")"

if [[ ! -f "$PROMPT" ]]; then
  echo "missing prompt: $PROMPT" >&2
  exit 1
fi
if [[ ! -f "$HOOK" ]]; then
  echo "missing hook: $HOOK" >&2
  exit 1
fi
if [[ "$REFLECTOR_RUNNER" != "auto" && "$REFLECTOR_RUNNER" != "claude" && "$REFLECTOR_RUNNER" != "codex" ]]; then
  echo "invalid --runner: $REFLECTOR_RUNNER" >&2
  exit 2
fi
if [[ "$REFLECT_MODE" != "immediate" && "$REFLECT_MODE" != "nightly" && "$REFLECT_MODE" != "off" ]]; then
  echo "invalid --reflect-mode: $REFLECT_MODE" >&2
  exit 2
fi

chmod +x "$HOOK" "$WORKER" "$REPO/hooks/frustration-stats.sh" "$REPO/scripts/introspect-status.sh" "$REPO/scripts/test-frustration-tripwire.py"

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

HOOK_COMMAND="env INTROSPECT_REFLECT_MODE=$(quote "$REFLECT_MODE") INTROSPECT_REPO=$(quote "$REPO") INTROSPECT_PROMPT=$(quote "$PROMPT") INTROSPECT_SKILLS_DIR=$(quote "$SKILLS_DIR") INTROSPECT_FEEDBACK_DIR=$(quote "$FEEDBACK_DIR") $(quote "$HOOK")"
HOOK_MODE="$MODE"
if [[ "$MODE" == "install" && "$REFLECT_MODE" == "off" ]]; then
  HOOK_MODE="uninstall"
fi

python3 - "$HOOK_MODE" "$HOOK_COMMAND" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import os
import sys
from pathlib import Path

mode = sys.argv[1]
hook_command = sys.argv[2]
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
    return isinstance(command, str) and "/hooks/frustration-reflect.sh" in command


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
                    "command": hook_command,
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

install_launch_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$FEEDBACK_DIR"
  python3 - "$LAUNCH_LABEL" "$REPO" "$WORKER" "$PROMPT" "$SKILLS_DIR" "$FEEDBACK_DIR" "$NIGHTLY_HOUR" "$NIGHTLY_MINUTE" "$REFLECTOR_RUNNER" "$LAUNCH_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

label, repo, worker, prompt, skills_dir, feedback_dir, hour, minute, runner, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/usr/bin/env", "python3", worker, "--nightly"],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "INTROSPECT_NOTIFY": "1",
        "INTROSPECT_REFLECT_MODE": "nightly",
        "INTROSPECT_REFLECT_MODE": "nightly",
        "INTROSPECT_REPO": repo,
        "INTROSPECT_PROMPT": prompt,
        "INTROSPECT_SKILLS_DIR": skills_dir,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_REFLECTOR_RUNNER": runner,
        "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    "StartCalendarInterval": {
        "Hour": int(hour),
        "Minute": int(minute),
    },
    "StandardOutPath": str(Path(feedback_dir) / "launchd.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "launchd.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
PY
  launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST"
  launchctl enable "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  echo "installed nightly reflector: $LAUNCH_PLIST at $(printf '%02d:%02d' "$NIGHTLY_HOUR" "$NIGHTLY_MINUTE") local, runner=$REFLECTOR_RUNNER"
}

uninstall_launch_agent() {
  launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  if [[ -f "$LAUNCH_PLIST" ]]; then
    rm "$LAUNCH_PLIST"
    echo "removed nightly reflector: $LAUNCH_PLIST"
  else
    echo "skip: nightly reflector not installed"
  fi
}

if [[ "$MODE" == "install" ]]; then
  if [[ "$REFLECT_MODE" == "nightly" ]]; then
    install_launch_agent
  else
    uninstall_launch_agent
    echo "reflector mode: $REFLECT_MODE"
  fi
  if [[ "$REFLECT_MODE" == "off" ]]; then
    echo "disabled Introspect hooks from $REPO"
  else
    echo "installed Introspect hooks from $REPO"
  fi
else
  uninstall_launch_agent
  echo "uninstalled Introspect hooks from $REPO"
fi
