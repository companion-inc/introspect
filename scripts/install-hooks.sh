#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="$REPO/hooks/trigger-reflect.sh"
WORKER="$REPO/hooks/trigger-worker.py"
SCANNER="$REPO/hooks/codex-transcript-scan.py"
MONITOR="$REPO/scripts/introspect-healthcheck.sh"
SKILL_SYNC="$REPO/scripts/sync-user-skills.sh"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
export STAMP

MODE="install"
PROMPT=""
SKILLS_DIR=""
USER_SKILLS_DIR=""
FEEDBACK_DIR=""
AGENTS_HOME_DIR="${AGENTS_HOME:-$HOME/.agents}"
INTROSPECT_HOME_DIR="${INTROSPECT_HOME:-$HOME/.introspect}"
REFLECT_MODE="immediate"
NIGHTLY_HOUR=3
NIGHTLY_MINUTE=0
REFLECTOR_RUNNER="default"
REFLECTOR_CLAUDE_MODEL=""
REFLECTOR_CLAUDE_FALLBACK_MODEL=""
REFLECTOR_CODEX_MODEL=""
WAKE_SHADOW_MODELS="${INTROSPECT_WAKE_SHADOW_MODELS:-}"
WAKE_SENSITIVITY="${INTROSPECT_WAKE_SENSITIVITY:-balanced}"
WAKE_THRESHOLD="${INTROSPECT_WAKE_THRESHOLD:-}"
BACKFILL_DAYS="${INTROSPECT_BACKFILL_DAYS:-7}"
BACKFILL_MAX_EVENTS="${INTROSPECT_BACKFILL_MAX_EVENTS:-500}"
BACKFILL_ENABLED="${INTROSPECT_BACKFILL_ENABLED:-1}"
BACKFILL_FORCE="${INTROSPECT_FORCE_BACKFILL:-0}"
BACKFILL_SCHEMA_VERSION=2
LAUNCHD_PATH="$HOME/.npm-global/bin:$HOME/.local/bin:$HOME/.bun/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
LAUNCH_LABEL="ai.companion.introspect.reflector"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
SCAN_LABEL="ai.companion.introspect.codex-scanner"
SCAN_PLIST="$HOME/Library/LaunchAgents/$SCAN_LABEL.plist"
MONITOR_LABEL="ai.companion.introspect.health"
MONITOR_PLIST="$HOME/Library/LaunchAgents/$MONITOR_LABEL.plist"
SETUP_PYTHON="${INTROSPECT_SETUP_PYTHON:-/usr/bin/python3}"
DEFAULT_PROMPT_TEMPLATE="$REPO/templates/default-AGENTS.md"

usage() {
  cat <<EOF
Usage: $0 [--uninstall] [--prompt PATH] [--skills PATH] [--user-skills PATH] [--feedback-dir PATH] [--home PATH] [--agents-home PATH] [--reflect-mode immediate|nightly|off] [--nightly-hour H] [--nightly-minute M] [--runner default|claude|codex] [--claude-model MODEL] [--codex-model MODEL] [--wake-sensitivity quiet|balanced|sensitive|custom] [--wake-threshold DECIMAL] [--backfill-days DAYS] [--backfill-max-events N] [--no-backfill] [--force-backfill]

install          Link native Claude/Codex/OpenCode prompt files and configure hooks.
--uninstall      Remove Introspect prompt links, hooks, scanner, monitor, and reflector LaunchAgents.
--home           Introspect private home. Default: ~/.introspect.
--agents-home    Agent-compatible skill export home. Default: ~/.agents.
--reflect-mode   immediate kicks the locked worker after trigger; nightly queues for the LaunchAgent; off removes hooks but keeps prompt links.
--runner         Reflector runner. default picks the installed agent with the most recent local usage; claude/codex force one.
--claude-model   Optional Claude model alias/id for reflector runs. Blank/default/auto uses Claude CLI default.
--codex-model    Optional Codex model id for reflector runs. Blank/default/auto uses Codex CLI default.
--wake-sensitivity
                 Classifier wake sensitivity. balanced uses the model threshold.
--wake-threshold Optional custom wake threshold, used when sensitivity=custom.
--backfill-days One-time local Claude/Codex history backfill window on install. Default: 7.
--backfill-max-events
                 Max historical prompt events to score on install. Default: 500.
--no-backfill    Skip the one-time local history backfill on install.
--force-backfill Run the bounded history backfill again even when a previous backfill completed.
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
    --user-skills)
      USER_SKILLS_DIR="${2:-}"
      shift 2
      ;;
    --feedback-dir)
      FEEDBACK_DIR="${2:-}"
      shift 2
      ;;
    --home|--introspect-home)
      INTROSPECT_HOME_DIR="${2:-}"
      shift 2
      ;;
    --agents-home)
      AGENTS_HOME_DIR="${2:-}"
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
    --wake-sensitivity)
      WAKE_SENSITIVITY="${2:-}"
      shift 2
      ;;
    --wake-threshold|--wake-custom-threshold)
      WAKE_THRESHOLD="${2:-}"
      shift 2
      ;;
    --backfill-days)
      BACKFILL_DAYS="${2:-}"
      shift 2
      ;;
    --backfill-max-events)
      BACKFILL_MAX_EVENTS="${2:-}"
      shift 2
      ;;
    --no-backfill)
      BACKFILL_ENABLED="0"
      shift
      ;;
    --force-backfill)
      BACKFILL_FORCE="1"
      shift
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

quote() {
  printf "%q" "$1"
}

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

reflector_model_summary() {
  local summary="reflector models: claude=${REFLECTOR_CLAUDE_MODEL:-default} codex=${REFLECTOR_CODEX_MODEL:-default}"
  if [[ -n "$REFLECTOR_CLAUDE_FALLBACK_MODEL" ]]; then
    summary="$summary claude_cli_fallback_model=$REFLECTOR_CLAUDE_FALLBACK_MODEL"
  fi
  echo "$summary"
}

case "$WAKE_SENSITIVITY" in
  quiet|balanced|sensitive|custom) ;;
  *)
    echo "invalid wake sensitivity: $WAKE_SENSITIVITY" >&2
    exit 2
    ;;
esac

prepend_tool_dir_to_launchd_path() {
  local tool="$1"
  local tool_path
  tool_path="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -z "$tool_path" ]]; then
    return
  fi
  local tool_dir
  tool_dir="$(dirname "$tool_path")"
  case ":$LAUNCHD_PATH:" in
    *":$tool_dir:"*) ;;
    *) LAUNCHD_PATH="$tool_dir:$LAUNCHD_PATH" ;;
  esac
}

prepend_tool_dir_to_launchd_path codex
prepend_tool_dir_to_launchd_path claude

AGENTS_HOME_DIR="$(expand_path "$AGENTS_HOME_DIR")"
INTROSPECT_HOME_DIR="$(expand_path "$INTROSPECT_HOME_DIR")"
OLD_AGENTS_INTROSPECT_HOME="$(expand_path "$AGENTS_HOME_DIR/introspect")"

migrate_previous_home() {
  if [[ "$INTROSPECT_HOME_DIR" == "$OLD_AGENTS_INTROSPECT_HOME" ]]; then
    return
  fi
  if [[ ! -e "$INTROSPECT_HOME_DIR" && -d "$OLD_AGENTS_INTROSPECT_HOME" ]]; then
    mkdir -p "$(dirname "$INTROSPECT_HOME_DIR")"
    mv "$OLD_AGENTS_INTROSPECT_HOME" "$INTROSPECT_HOME_DIR"
    echo "migrated private home: $OLD_AGENTS_INTROSPECT_HOME -> $INTROSPECT_HOME_DIR"
  fi
}

remove_old_agents_prompt_bridge() {
  local link="$AGENTS_HOME_DIR/AGENTS.md"
  local target=""
  target="$(readlink "$link" 2>/dev/null || true)"
  case "$target" in
    "$INTROSPECT_HOME_DIR/AGENTS.md"|"$OLD_AGENTS_INTROSPECT_HOME/AGENTS.md")
      rm "$link"
      echo "removed old public bridge: $link"
      ;;
  esac
}

ensure_home_files() {
  mkdir -p "$AGENTS_HOME_DIR" "$INTROSPECT_HOME_DIR/skills" "$INTROSPECT_HOME_DIR/memory" "$INTROSPECT_HOME_DIR/models" "$INTROSPECT_HOME_DIR/feedback" "$INTROSPECT_HOME_DIR/runs" "$INTROSPECT_HOME_DIR/proposals"
  if [[ ! -f "$INTROSPECT_HOME_DIR/AGENTS.md" ]]; then
    if [[ -f "$DEFAULT_PROMPT_TEMPLATE" ]]; then
      cp "$DEFAULT_PROMPT_TEMPLATE" "$INTROSPECT_HOME_DIR/AGENTS.md"
    else
      printf '# AGENTS.md\n\n## Mission\n\n- Add global user-wide agent guidance here.\n' > "$INTROSPECT_HOME_DIR/AGENTS.md"
    fi
  fi
  if [[ ! -f "$INTROSPECT_HOME_DIR/skills/index.json" ]]; then
    printf '{\n  "version": 1,\n  "skills": []\n}\n' > "$INTROSPECT_HOME_DIR/skills/index.json"
  fi
  if [[ ! -f "$INTROSPECT_HOME_DIR/models/wake-logreg-v2-round4.json" && -f "$REPO/models/wake-logreg-v2-round4.json" ]]; then
    cp "$REPO/models/wake-logreg-v2-round4.json" "$INTROSPECT_HOME_DIR/models/wake-logreg-v2-round4.json"
  fi
  if [[ ! -f "$INTROSPECT_HOME_DIR/settings.json" ]]; then
    cat > "$INTROSPECT_HOME_DIR/settings.json" <<JSON
{
  "notifications_enabled": true,
  "reflect_mode": "$REFLECT_MODE",
  "reflector_runner": "$REFLECTOR_RUNNER",
  "reflector_claude_model": "",
  "reflector_claude_fallback_model": "",
  "reflector_codex_model": "",
  "wake_sensitivity": "$WAKE_SENSITIVITY",
  "wake_custom_threshold": ${WAKE_THRESHOLD:-0.64},
  "nightly_hour": $NIGHTLY_HOUR,
  "nightly_minute": $NIGHTLY_MINUTE
}
JSON
  fi
  if [[ ! -f "$INTROSPECT_HOME_DIR/README.md" ]]; then
    cat > "$INTROSPECT_HOME_DIR/README.md" <<'MD'
# Introspect Home

This repository is private local state for Introspect:

- `AGENTS.md`: the Git-tracked source for the user-wide prompt linked into each agent's native prompt file.
- `trigger-words.txt`: optional review terms, one lowercase word per line. Introspect does not install defaults.
- `settings.json`: local app preferences such as notification delivery.
- `skills/`: private user skills.
- `memory/`: durable user and machine facts.
- `feedback/`: ignored local trigger queues, logs, and run artifacts.
- `runs/`: ignored local run artifacts.
- `proposals/`: reflector proposals before they are accepted.
- `models/`: ignored local model artifacts seeded or produced by Introspect.

Durable prompt, settings, skill, and memory changes are Git-tracked. Runtime artifacts stay local and ignored.
MD
  fi
  "$SETUP_PYTHON" - "$INTROSPECT_HOME_DIR/README.md" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
try:
    text = path.read_text()
except OSError:
    raise SystemExit(0)
updated = text.replace("~/.agents/introspect", "~/.introspect")
updated = updated.replace(
    "the Git-tracked source for the user-wide prompt exposed at `~/.agents/AGENTS.md`",
    "the Git-tracked source for the user-wide prompt linked into each agent's native prompt file",
)
if updated != text:
    path.write_text(updated)
PY
  touch "$INTROSPECT_HOME_DIR/.gitignore"
  for entry in "feedback/" "runs/" "proposals/" "models/*.json" "models/*.json.*"; do
    if ! grep -Fxq "$entry" "$INTROSPECT_HOME_DIR/.gitignore"; then
      printf '%s\n' "$entry" >> "$INTROSPECT_HOME_DIR/.gitignore"
    fi
  done
  if [[ ! -d "$INTROSPECT_HOME_DIR/.git" ]]; then
    git init "$INTROSPECT_HOME_DIR" >/dev/null
  fi
  if [[ -z "$(git -C "$INTROSPECT_HOME_DIR" config --local user.name 2>/dev/null || true)" ]]; then
    git -C "$INTROSPECT_HOME_DIR" config --local user.name "Introspect"
  fi
  if [[ -z "$(git -C "$INTROSPECT_HOME_DIR" config --local user.email 2>/dev/null || true)" ]]; then
    git -C "$INTROSPECT_HOME_DIR" config --local user.email "introspect@local"
  fi
}

if [[ "$MODE" == "install" ]]; then
  migrate_previous_home
  ensure_home_files
  git -C "$INTROSPECT_HOME_DIR" add . >/dev/null 2>&1 || true
  if [[ -d "$INTROSPECT_HOME_DIR/.git" ]] && [[ -n "$(git -C "$INTROSPECT_HOME_DIR" status --porcelain 2>/dev/null || true)" ]]; then
    git -C "$INTROSPECT_HOME_DIR" commit -m "Update Introspect home" >/dev/null 2>&1 || true
  fi
fi

if [[ -z "$PROMPT" ]]; then
  PROMPT="$INTROSPECT_HOME_DIR/AGENTS.md"
fi

PROMPT="$(expand_path "$PROMPT")"
if [[ -z "$SKILLS_DIR" ]]; then
  SKILLS_DIR="$REPO/skills"
fi
SKILLS_DIR="$(expand_path "$SKILLS_DIR")"
if [[ -z "$USER_SKILLS_DIR" ]]; then
  USER_SKILLS_DIR="$INTROSPECT_HOME_DIR/skills"
fi
USER_SKILLS_DIR="$(expand_path "$USER_SKILLS_DIR")"
if [[ -z "$FEEDBACK_DIR" ]]; then
  case "$REPO" in
    *.app/Contents/Resources)
      FEEDBACK_DIR="$INTROSPECT_HOME_DIR/feedback"
      ;;
    *)
      FEEDBACK_DIR="$REPO/feedback"
      ;;
  esac
fi
FEEDBACK_DIR="$(expand_path "$FEEDBACK_DIR")"

discover_shadow_models() {
  if [[ -n "$WAKE_SHADOW_MODELS" ]]; then
    return
  fi
  local specs=()
  local r8="$FEEDBACK_DIR/intent-classifier/wake-logreg-v2-round8-holdout-selected.json"
  local r9="$FEEDBACK_DIR/intent-classifier/wake-logreg-v2-round9-holdout-selected.json"
  local r8r9="$FEEDBACK_DIR/intent-classifier/wake-logreg-v2-round8-after-round9-selected.json"
  if [[ -f "$r8" ]]; then
    specs+=("r8-retrain=$r8")
  fi
  if [[ -f "$r9" ]]; then
    specs+=("r9-retrain=$r9")
  fi
  if [[ -f "$r8r9" ]]; then
    specs+=("r8-r9=$r8r9")
  fi
  local IFS=,
  WAKE_SHADOW_MODELS="${specs[*]-}"
}

discover_shadow_models

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
if [[ ! -f "$SKILL_SYNC" ]]; then
  echo "missing skill sync: $SKILL_SYNC" >&2
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

case "$REPO" in
  *.app/Contents/Resources)
    ;;
  *)
    chmod +x "$HOOK" "$WORKER" "$SCANNER" "$MONITOR" "$SKILL_SYNC" "$REPO/hooks/trigger-stats.sh" "$REPO/scripts/introspect-status.sh" "$REPO/scripts/test-trigger-words.py" "$REPO/scripts/test-surface-scopes.py" "$REPO/scripts/test-reflector-prompt-contract.py" "$REPO/scripts/test-user-skill-sync.sh" "$REPO/scripts/test-install-paths.sh"
    ;;
esac

if [[ "$MODE" == "install" ]]; then
  remove_old_agents_prompt_bridge
  install_link "$PROMPT" "$HOME/.claude/CLAUDE.md"
  install_link "$PROMPT" "$HOME/.codex/AGENTS.md"
  install_link "$PROMPT" "$HOME/.config/opencode/AGENTS.md"
  echo "configured private home: $INTROSPECT_HOME_DIR"
  echo "configured native prompt links: ~/.claude/CLAUDE.md ~/.codex/AGENTS.md ~/.config/opencode/AGENTS.md"
  INTROSPECT_HOME="$INTROSPECT_HOME_DIR" INTROSPECT_USER_SKILLS_DIR="$USER_SKILLS_DIR" /bin/bash "$SKILL_SYNC"
else
  uninstall_link "$PROMPT" "$HOME/.claude/CLAUDE.md"
  uninstall_link "$PROMPT" "$HOME/.codex/AGENTS.md"
  uninstall_link "$PROMPT" "$HOME/.config/opencode/AGENTS.md"
  remove_old_agents_prompt_bridge
  INTROSPECT_HOME="$INTROSPECT_HOME_DIR" INTROSPECT_USER_SKILLS_DIR="$USER_SKILLS_DIR" /bin/bash "$SKILL_SYNC" --unlink
fi

HOOK_COMMAND="env PYTHONDONTWRITEBYTECODE=1 INTROSPECT_REFLECT_MODE=$(quote "$REFLECT_MODE") INTROSPECT_REPO=$(quote "$REPO") AGENTS_HOME=$(quote "$AGENTS_HOME_DIR") INTROSPECT_PROMPT=$(quote "$PROMPT") INTROSPECT_SKILLS_DIR=$(quote "$SKILLS_DIR") INTROSPECT_USER_SKILLS_DIR=$(quote "$USER_SKILLS_DIR") INTROSPECT_FEEDBACK_DIR=$(quote "$FEEDBACK_DIR") INTROSPECT_HOME=$(quote "$INTROSPECT_HOME_DIR") INTROSPECT_WAKE_MODEL=$(quote "$INTROSPECT_HOME_DIR/models/wake-logreg-v2-round4.json") INTROSPECT_WAKE_SHADOW_MODELS=$(quote "$WAKE_SHADOW_MODELS") INTROSPECT_WAKE_SENSITIVITY=$(quote "$WAKE_SENSITIVITY") INTROSPECT_WAKE_THRESHOLD=$(quote "$WAKE_THRESHOLD") $(quote "$HOOK")"
HOOK_MODE="$MODE"
if [[ "$MODE" == "install" && "$REFLECT_MODE" == "off" ]]; then
  HOOK_MODE="uninstall"
fi

"$SETUP_PYTHON" - "$HOOK_MODE" "$HOOK_COMMAND" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
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
  "$SETUP_PYTHON" - "$LAUNCH_LABEL" "$REPO" "$WORKER" "$PROMPT" "$SKILLS_DIR" "$USER_SKILLS_DIR" "$FEEDBACK_DIR" "$AGENTS_HOME_DIR" "$INTROSPECT_HOME_DIR" "$NIGHTLY_HOUR" "$NIGHTLY_MINUTE" "$REFLECTOR_RUNNER" "$REFLECTOR_CLAUDE_MODEL" "$REFLECTOR_CLAUDE_FALLBACK_MODEL" "$REFLECTOR_CODEX_MODEL" "$WAKE_SENSITIVITY" "$WAKE_THRESHOLD" "$LAUNCHD_PATH" "$LAUNCH_PLIST" <<'PY'
import plistlib
import os
import sys
from pathlib import Path

label, repo, worker, prompt, skills_dir, user_skills_dir, feedback_dir, agents_home_dir, home_dir, hour, minute, runner, claude_model, claude_fallback_model, codex_model, wake_sensitivity, wake_threshold, launchd_path, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/usr/bin/env", "python3", worker, "--nightly"],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "PYTHONDONTWRITEBYTECODE": "1",
        "INTROSPECT_REFLECT_MODE": "nightly",
        "INTROSPECT_REPO": repo,
        "AGENTS_HOME": agents_home_dir,
        "INTROSPECT_PROMPT": prompt,
        "INTROSPECT_SKILLS_DIR": skills_dir,
        "INTROSPECT_USER_SKILLS_DIR": user_skills_dir,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_HOME": home_dir,
        "INTROSPECT_WAKE_MODEL": str(Path(home_dir) / "models" / "wake-logreg-v2-round4.json"),
        "INTROSPECT_REFLECTOR_RUNNER": runner,
        "INTROSPECT_REFLECTOR_CLAUDE_MODEL": claude_model,
        "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL": claude_fallback_model,
        "INTROSPECT_REFLECTOR_CODEX_MODEL": codex_model,
        "INTROSPECT_WAKE_SENSITIVITY": wake_sensitivity,
        "INTROSPECT_WAKE_THRESHOLD": wake_threshold,
        "PATH": launchd_path,
    },
    "StartCalendarInterval": {
        "Hour": int(hour),
        "Minute": int(minute),
    },
    "StandardOutPath": str(Path(feedback_dir) / "launchd.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "launchd.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
os._exit(0)
PY
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" == "1" ]]; then
    echo "wrote nightly reflector: $LAUNCH_PLIST (launchd bootstrap skipped)"
    return
  fi
  launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$LAUNCH_PLIST"
  launchctl enable "gui/$(id -u)/$LAUNCH_LABEL" >/dev/null 2>&1 || true
  echo "installed nightly reflector: $LAUNCH_PLIST at $(printf '%02d:%02d' "$NIGHTLY_HOUR" "$NIGHTLY_MINUTE") local, runner=$REFLECTOR_RUNNER"
  reflector_model_summary
}

uninstall_launch_agent() {
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)" "$LAUNCH_PLIST" >/dev/null 2>&1 || true
  fi
  if [[ -f "$LAUNCH_PLIST" ]]; then
    rm "$LAUNCH_PLIST"
    echo "removed nightly reflector: $LAUNCH_PLIST"
  else
    echo "skip: nightly reflector not installed"
  fi
}

install_scan_agent() {
  mkdir -p "$HOME/Library/LaunchAgents" "$FEEDBACK_DIR"
  "$SETUP_PYTHON" - "$SCAN_LABEL" "$REPO" "$SCANNER" "$PROMPT" "$SKILLS_DIR" "$USER_SKILLS_DIR" "$FEEDBACK_DIR" "$AGENTS_HOME_DIR" "$INTROSPECT_HOME_DIR" "$REFLECT_MODE" "$REFLECTOR_RUNNER" "$REFLECTOR_CLAUDE_MODEL" "$REFLECTOR_CLAUDE_FALLBACK_MODEL" "$REFLECTOR_CODEX_MODEL" "$WAKE_SHADOW_MODELS" "$WAKE_SENSITIVITY" "$WAKE_THRESHOLD" "$LAUNCHD_PATH" "$SCAN_PLIST" <<'PY'
import plistlib
import os
import sys
from pathlib import Path

label, repo, scanner, prompt, skills_dir, user_skills_dir, feedback_dir, agents_home_dir, home_dir, reflect_mode, runner, claude_model, claude_fallback_model, codex_model, wake_shadow_models, wake_sensitivity, wake_threshold, launchd_path, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/usr/bin/env", "python3", scanner],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "PYTHONDONTWRITEBYTECODE": "1",
        "INTROSPECT_REFLECT_MODE": reflect_mode,
        "INTROSPECT_REPO": repo,
        "AGENTS_HOME": agents_home_dir,
        "INTROSPECT_PROMPT": prompt,
        "INTROSPECT_SKILLS_DIR": skills_dir,
        "INTROSPECT_USER_SKILLS_DIR": user_skills_dir,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_HOME": home_dir,
        "INTROSPECT_WAKE_MODEL": str(Path(home_dir) / "models" / "wake-logreg-v2-round4.json"),
        "INTROSPECT_REFLECTOR_RUNNER": runner,
        "INTROSPECT_REFLECTOR_CLAUDE_MODEL": claude_model,
        "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL": claude_fallback_model,
        "INTROSPECT_REFLECTOR_CODEX_MODEL": codex_model,
        "INTROSPECT_WAKE_SHADOW_MODELS": wake_shadow_models,
        "INTROSPECT_WAKE_SENSITIVITY": wake_sensitivity,
        "INTROSPECT_WAKE_THRESHOLD": wake_threshold,
        "INTROSPECT_CODEX_SCAN_MINUTES": "20",
        "PATH": launchd_path,
    },
    # Event-driven, not polled: launchd wakes the scanner when Codex writes
    # session history or Claude writes project history. Codex's own hook can
    # be skipped, and assistant-output failures never pass through user-prompt
    # hooks, so the transcript scanner is the backstop without a timer.
    "WatchPaths": [
        str(Path.home() / ".codex" / "history.jsonl"),
        str(Path.home() / ".codex" / "sessions"),
        str(Path.home() / ".claude" / "projects"),
    ],
    "RunAtLoad": True,
    "StandardOutPath": str(Path(feedback_dir) / "codex-scanner.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "codex-scanner.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
os._exit(0)
PY
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" == "1" ]]; then
    echo "wrote transcript scanner: $SCAN_PLIST (launchd bootstrap skipped)"
    return
  fi
  launchctl bootout "gui/$(id -u)" "$SCAN_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$SCAN_PLIST"
  launchctl enable "gui/$(id -u)/$SCAN_LABEL" >/dev/null 2>&1 || true
  echo "installed transcript scanner: $SCAN_PLIST (event-driven on Codex/Claude writes; no polling)"
  if [[ -n "$WAKE_SHADOW_MODELS" ]]; then
    echo "shadow candidate models: $WAKE_SHADOW_MODELS"
  fi
  reflector_model_summary
}

run_initial_backfill() {
  if [[ "$REFLECT_MODE" == "off" || "$BACKFILL_ENABLED" == "0" || "${INTROSPECT_SKIP_BACKFILL:-0}" == "1" ]]; then
    echo "skip: initial local agent history backfill"
    return
  fi
  mkdir -p "$FEEDBACK_DIR"
  if [[ "$BACKFILL_FORCE" != "1" ]] && "$SETUP_PYTHON" - "$FEEDBACK_DIR/codex-transcript-scan-state.json" "$BACKFILL_SCHEMA_VERSION" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
expected = int(sys.argv[2])
try:
    state = json.loads(path.read_text())
except Exception:
    raise SystemExit(1)
try:
    actual = int(state.get("last_backfill_schema_version") or 1)
except Exception:
    actual = 1
raise SystemExit(0 if state.get("last_backfill_at") and actual >= expected else 1)
PY
  then
    echo "skip: initial local agent history backfill already completed"
    return
  fi
  if ! env \
    PYTHONDONTWRITEBYTECODE=1 \
    INTROSPECT_REFLECT_MODE="$REFLECT_MODE" \
    INTROSPECT_REPO="$REPO" \
    AGENTS_HOME="$AGENTS_HOME_DIR" \
    INTROSPECT_PROMPT="$PROMPT" \
    INTROSPECT_SKILLS_DIR="$SKILLS_DIR" \
    INTROSPECT_USER_SKILLS_DIR="$USER_SKILLS_DIR" \
    INTROSPECT_FEEDBACK_DIR="$FEEDBACK_DIR" \
    INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
    INTROSPECT_WAKE_MODEL="$INTROSPECT_HOME_DIR/models/wake-logreg-v2-round4.json" \
    INTROSPECT_WAKE_SHADOW_MODELS="$WAKE_SHADOW_MODELS" \
    INTROSPECT_WAKE_SENSITIVITY="$WAKE_SENSITIVITY" \
    INTROSPECT_WAKE_THRESHOLD="$WAKE_THRESHOLD" \
    "$SETUP_PYTHON" "$SCANNER" --backfill --since-days "$BACKFILL_DAYS" --max-events "$BACKFILL_MAX_EVENTS" --no-queue --no-kick; then
    echo "warn: initial local agent history backfill failed; install continued" >&2
  fi
}

uninstall_scan_agent() {
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)" "$SCAN_PLIST" >/dev/null 2>&1 || true
  fi
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
  "$SETUP_PYTHON" - "$MONITOR_LABEL" "$REPO" "$MONITOR" "$FEEDBACK_DIR" "$INTROSPECT_HOME_DIR" "$LAUNCHD_PATH" "$MONITOR_PLIST" <<'PY'
import plistlib
import os
import sys
from pathlib import Path

label, repo, monitor, feedback_dir, home_dir, launchd_path, plist_path = sys.argv[1:]
data = {
    "Label": label,
    "ProgramArguments": ["/bin/bash", monitor],
    "WorkingDirectory": repo,
    "EnvironmentVariables": {
        "PYTHONDONTWRITEBYTECODE": "1",
        "INTROSPECT_REPO": repo,
        "INTROSPECT_FEEDBACK_DIR": feedback_dir,
        "INTROSPECT_HOME": home_dir,
        "PATH": launchd_path,
    },
    # Runs once at login to repair setup drift, then stays idle. No polling
    # timer — the app also self-repairs whenever you open it.
    "RunAtLoad": True,
    "StandardOutPath": str(Path(feedback_dir) / "healthcheck.out.log"),
    "StandardErrorPath": str(Path(feedback_dir) / "healthcheck.err.log"),
}
Path(plist_path).write_bytes(plistlib.dumps(data, sort_keys=False))
os._exit(0)
PY
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" == "1" ]]; then
    echo "wrote Introspect health monitor: $MONITOR_PLIST (launchd bootstrap skipped)"
    return
  fi
  launchctl bootout "gui/$(id -u)" "$MONITOR_PLIST" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$MONITOR_PLIST"
  launchctl enable "gui/$(id -u)/$MONITOR_LABEL" >/dev/null 2>&1 || true
  echo "installed Introspect health monitor: $MONITOR_PLIST (runs at login only; no polling)"
}

uninstall_monitor_agent() {
  if [[ "${INTROSPECT_SKIP_LAUNCHD:-0}" != "1" ]]; then
    launchctl bootout "gui/$(id -u)" "$MONITOR_PLIST" >/dev/null 2>&1 || true
  fi
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
    run_initial_backfill
    echo "installed Introspect hooks from $REPO"
  fi
else
  uninstall_launch_agent
  uninstall_scan_agent
  uninstall_monitor_agent
  echo "uninstalled Introspect hooks from $REPO"
fi
