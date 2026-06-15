#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="$REPO/hooks/trigger-reflect.sh"
WORKER="$REPO/hooks/trigger-worker.py"
SCANNER="$REPO/hooks/codex-transcript-scan.py"
MONITOR="$REPO/scripts/introspect-healthcheck.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP

MODE="install"
PROMPT=""
SKILLS_DIR=""
FEEDBACK_DIR=""
PROFILE_DIR="${INTROSPECT_PROFILE_DIR:-$HOME/.introspect/profile}"
REFLECT_MODE="immediate"
NIGHTLY_HOUR=3
NIGHTLY_MINUTE=0
REFLECTOR_RUNNER="default"
REFLECTOR_CLAUDE_MODEL=""
REFLECTOR_CLAUDE_FALLBACK_MODEL=""
REFLECTOR_CODEX_MODEL=""
LAUNCH_LABEL="ai.companion.introspect.reflector"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
SCAN_LABEL="ai.companion.introspect.codex-scanner"
SCAN_PLIST="$HOME/Library/LaunchAgents/$SCAN_LABEL.plist"
MONITOR_LABEL="ai.companion.introspect.health"
MONITOR_PLIST="$HOME/Library/LaunchAgents/$MONITOR_LABEL.plist"

usage() {
  cat <<EOF
Usage: $0 [--uninstall] [--prompt PATH] [--skills PATH] [--feedback-dir PATH] [--profile-dir PATH] [--reflect-mode immediate|nightly|off] [--nightly-hour H] [--nightly-minute M] [--runner default|claude|codex] [--claude-model MODEL] [--claude-fallback-model MODEL] [--codex-model MODEL]

install          Link this repo's prompt and configure Claude/Codex hooks.
--uninstall      Remove this repo's prompt links, hooks, scanner, monitor, and reflector LaunchAgents.
--reflect-mode   immediate kicks the locked worker after trigger; nightly queues for the LaunchAgent; off removes hooks but keeps prompt links.
--runner         Reflector runner. default picks the installed agent with the most recent local usage; claude/codex force one.
--claude-model   Optional Claude model alias/id for reflector runs. Blank/default/auto uses Claude CLI default.
--claude-fallback-model
                 Optional Claude fallback model list for reflector runs.
--codex-model    Optional Codex model id for reflector runs. Blank/default/auto uses Codex CLI default.
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
    --profile-dir)
      PROFILE_DIR="${2:-}"
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
    --claude-model)
      REFLECTOR_CLAUDE_MODEL="${2:-}"
      shift 2
      ;;
    --claude-fallback-model)
      REFLECTOR_CLAUDE_FALLBACK_MODEL="${2:-}"
      shift 2
      ;;
    --codex-model)
      REFLECTOR_CODEX_MODEL="${2:-}"
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
PROFILE_DIR="$(expand_path "$PROFILE_DIR")"

if [[ ! -f "$PROMPT" ]]; then
  echo "missing prompt: $PROMPT" >&2
  exit 1
fi
if [[ ! -f "$HOOK" ]]; then
  echo "missing hook: $HOOK" >&2
  exit 1
fi
if [[ ! -f "$SCANNER" ]]; then
  echo "missing scanner: $SCANNER" >&2
  exit 1
fi
if [[ ! -f "$MONITOR" ]]; then
  echo "missing health monitor: $MONITOR" >&2
  exit 1
fi
if [[ "$REFLECTOR_RUNNER" == "auto" || "$REFLECTOR_RUNNER" == "most-used" || "$REFLECTOR_RUNNER" == "most_used" ]]; then
  REFLECTOR_RUNNER="default"
fi
if [[ "$REFLECTOR_RUNNER" != "default" && "$REFLECTOR_RUNNER" != "claude" && "$REFLECTOR_RUNNER" != "codex" ]]; then
  echo "invalid --runner: $REFLECTOR_RUNNER" >&2
  exit 2
fi
normalize_model_setting() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    ""|"default"|"auto")
      printf ''
      ;;
    *)
      printf '%s' "$1"
      ;;
  esac
}
REFLECTOR_CLAUDE_MODEL="$(normalize_model_setting "$REFLECTOR_CLAUDE_MODEL")"
REFLECTOR_CLAUDE_FALLBACK_MODEL="$(normalize_model_setting "$REFLECTOR_CLAUDE_FALLBACK_MODEL")"
REFLECTOR_CODEX_MODEL="$(normalize_model_setting "$REFLECTOR_CODEX_MODEL")"
if [[ "$REFLECT_MODE" != "immediate" && "$REFLECT_MODE" != "nightly" && "$REFLECT_MODE" != "off" ]]; then
  echo "invalid --reflect-mode: $REFLECT_MODE" >&2
  exit 2
fi

chmod +x "$HOOK" "$WORKER" "$SCANNER" "$MONITOR" "$REPO/hooks/trigger-stats.sh" "$REPO/scripts/introspect-status.sh" "$REPO/scripts/test-trigger-words.py"

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

HOOK_COMMAND="env INTROSPECT_REFLECT_MODE=$(quote "$REFLECT_MODE") INTROSPECT_REPO=$(quote "$REPO") INTROSPECT_PROMPT=$(quote "$PROMPT") INTROSPECT_SKILLS_DIR=$(quote "$SKILLS_DIR") INTROSPECT_FEEDBACK_DIR=$(quote "$FEEDBACK_DIR") INTROSPECT_PROFILE_DIR=$(quote "$PROFILE_DIR") $(quote "$HOOK")"
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


def is_trigger_hook(hook: object) -> bool:
    if not isinstance(hook, dict):
        return False
    command = hook.get("command")
    return isinstance(command, str) and "/hooks/trigger-reflect.sh" in command


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


def remove_trigger_hooks(path: Path) -> tuple[dict, int]:
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
            if is_trigger_hook(hook):
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
    data, _removed = remove_trigger_hooks(path)
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
    data, removed = remove_trigger_hooks(path)
    changed = write_if_changed(path, data)
    if removed and changed:
        print(f"removed {removed} hook(s): {path}")
    elif removed:
        print(f"removed {removed} hook(s): {path}")
    else:
        print(f"skip: no trigger hook in {path}")


for settings_path in settings_paths:
    if mode == "install":
        install(settings_path)
    else:
        uninstall(settings_path)
PY

install_launch_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$FEEDBACK_DIR"
  python3 - "$LAUNCH_LABEL" "$REPO" "$WORKER" "$PROMPT" "$SKILLS_DIR" "$FEEDBACK_DIR" "$PROFILE_DIR" "$NIGHTLY_HOUR" "$NIGHTLY_MINUTE" "$REFLECTOR_RUNNER" "$REFLECTOR_CLAUDE_MODEL" "$REFLECTOR_CLAUDE_FALLBACK_MODEL" "$REFLECTOR_CODEX_MODEL" "$LAUNCH_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

label, repo, worker, prompt, skills_dir, feedback_dir, profile_dir, hour, minute, runner, claude_model, claude_fallback_model, codex_model, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/usr/bin/env", "python3", worker, "--nightly"],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "INTROSPECT_REFLECT_MODE": "nightly",
        "INTROSPECT_REPO": repo,
        "INTROSPECT_PROMPT": prompt,
        "INTROSPECT_SKILLS_DIR": skills_dir,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_PROFILE_DIR": profile_dir,
        "INTROSPECT_REFLECTOR_RUNNER": runner,
        "INTROSPECT_REFLECTOR_CLAUDE_MODEL": claude_model,
        "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL": claude_fallback_model,
        "INTROSPECT_REFLECTOR_CODEX_MODEL": codex_model,
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
  echo "reflector models: claude=${REFLECTOR_CLAUDE_MODEL:-default} fallback=${REFLECTOR_CLAUDE_FALLBACK_MODEL:-none} codex=${REFLECTOR_CODEX_MODEL:-default}"
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

install_scan_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$FEEDBACK_DIR"
  python3 - "$SCAN_LABEL" "$REPO" "$SCANNER" "$PROMPT" "$SKILLS_DIR" "$FEEDBACK_DIR" "$PROFILE_DIR" "$REFLECT_MODE" "$REFLECTOR_RUNNER" "$REFLECTOR_CLAUDE_MODEL" "$REFLECTOR_CLAUDE_FALLBACK_MODEL" "$REFLECTOR_CODEX_MODEL" "$SCAN_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

label, repo, scanner, prompt, skills_dir, feedback_dir, profile_dir, reflect_mode, runner, claude_model, claude_fallback_model, codex_model, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/usr/bin/env", "python3", scanner],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "INTROSPECT_REFLECT_MODE": reflect_mode,
        "INTROSPECT_REPO": repo,
        "INTROSPECT_PROMPT": prompt,
        "INTROSPECT_SKILLS_DIR": skills_dir,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_PROFILE_DIR": profile_dir,
        "INTROSPECT_REFLECTOR_RUNNER": runner,
        "INTROSPECT_REFLECTOR_CLAUDE_MODEL": claude_model,
        "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL": claude_fallback_model,
        "INTROSPECT_REFLECTOR_CODEX_MODEL": codex_model,
        "INTROSPECT_CODEX_SCAN_MINUTES": "20",
        "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    # Event-driven, not polled: launchd wakes the scanner only when Codex
    # actually writes (a new prompt appends to history.jsonl; a new session
    # adds a rollout file). Codex's own hook is unreliable, so this is the
    # backstop that catches the triggers it drops — without a timer.
    "WatchPaths": [
        str(Path.home() / ".codex" / "history.jsonl"),
        str(Path.home() / ".codex" / "sessions"),
    ],
    "RunAtLoad": True,
    "StandardOutPath": str(Path(feedback_dir) / "codex-scanner.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "codex-scanner.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
PY
  launchctl bootout "gui/$(id -u)" "$SCAN_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$SCAN_PLIST"
  launchctl enable "gui/$(id -u)/$SCAN_LABEL" >/dev/null 2>&1 || true
  echo "installed Codex transcript scanner: $SCAN_PLIST (event-driven on Codex writes; no polling)"
  echo "reflector models: claude=${REFLECTOR_CLAUDE_MODEL:-default} fallback=${REFLECTOR_CLAUDE_FALLBACK_MODEL:-none} codex=${REFLECTOR_CODEX_MODEL:-default}"
}

uninstall_scan_agent() {
  launchctl bootout "gui/$(id -u)" "$SCAN_PLIST" >/dev/null 2>&1 || true
  if [[ -f "$SCAN_PLIST" ]]; then
    rm "$SCAN_PLIST"
    echo "removed Codex transcript scanner: $SCAN_PLIST"
  else
    echo "skip: Codex transcript scanner not installed"
  fi
}

install_monitor_agent() {
  if [[ "${INTROSPECT_SKIP_MONITOR_BOOTSTRAP:-0}" == "1" ]]; then
    echo "skip: health monitor bootstrap while healthcheck is running"
    return
  fi
  mkdir -p "$HOME/Library/LaunchAgents" "$FEEDBACK_DIR"
  python3 - "$MONITOR_LABEL" "$REPO" "$MONITOR" "$FEEDBACK_DIR" "$PROFILE_DIR" "$MONITOR_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

label, repo, monitor, feedback_dir, profile_dir, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", monitor],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "INTROSPECT_REPO": repo,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_PROFILE_DIR": profile_dir,
        "PATH": "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    },
    # Runs once at login to repair setup drift, then stays idle. No polling
    # timer — the app also self-repairs whenever you open it.
    "RunAtLoad": True,
    "StandardOutPath": str(Path(feedback_dir) / "healthcheck.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "healthcheck.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
PY
  launchctl bootout "gui/$(id -u)" "$MONITOR_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$MONITOR_PLIST"
  launchctl enable "gui/$(id -u)/$MONITOR_LABEL" >/dev/null 2>&1 || true
  echo "installed Introspect health monitor: $MONITOR_PLIST (runs at login only; no polling)"
}

uninstall_monitor_agent() {
  launchctl bootout "gui/$(id -u)" "$MONITOR_PLIST" >/dev/null 2>&1 || true
  if [[ -f "$MONITOR_PLIST" ]]; then
    rm "$MONITOR_PLIST"
    echo "removed Introspect health monitor: $MONITOR_PLIST"
  else
    echo "skip: Introspect health monitor not installed"
  fi
}

if [[ "$MODE" == "install" ]]; then
  install_monitor_agent
  if [[ "$REFLECT_MODE" == "nightly" ]]; then
    install_launch_agent
  else
    uninstall_launch_agent
    echo "reflector mode: $REFLECT_MODE"
  fi
  if [[ "$REFLECT_MODE" == "off" ]]; then
    uninstall_scan_agent
    echo "disabled Introspect hooks from $REPO"
  else
    install_scan_agent
    echo "installed Introspect hooks from $REPO"
  fi
else
  uninstall_launch_agent
  uninstall_scan_agent
  uninstall_monitor_agent
  echo "uninstalled Introspect hooks from $REPO"
fi
