#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FEEDBACK_DIR="${INTROSPECT_FEEDBACK_DIR:-$REPO/feedback}"
INTROSPECT_HOME_DIR="${INTROSPECT_HOME:-$HOME/.introspect}"
SETTINGS="$INTROSPECT_HOME_DIR/settings.json"
PROMPT="$INTROSPECT_HOME_DIR/AGENTS.md"
LOG="$FEEDBACK_DIR/healthcheck.log"
LATEST="$FEEDBACK_DIR/health-status.latest"

mkdir -p "$FEEDBACK_DIR"
exec >>"$LOG" 2>&1

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

setting() {
  local key="$1"
  local fallback="$2"
  python3 - "$SETTINGS" "$key" "$fallback" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = json.loads(path.read_text())
except Exception:
    print(fallback)
    raise SystemExit(0)
value = data.get(key) if isinstance(data, dict) else None
if value is None:
    print(fallback)
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

plist_env_value() {
  local plist="$1"
  local key="$2"
  local fallback="$3"
  python3 - "$plist" "$key" "$fallback" <<'PY'
import plistlib
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
fallback = sys.argv[3]
try:
    data = plistlib.loads(path.read_bytes())
except Exception:
    print(fallback)
    raise SystemExit(0)
env = data.get("EnvironmentVariables", {})
value = env.get(key, fallback) if isinstance(env, dict) else fallback
print(value if isinstance(value, str) else fallback)
PY
}

check_plist_env() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(plist_env_value "$plist" "$key" "__missing__")"
  if [[ "$actual" != "$expected" ]]; then
    needs_repair=1
    reasons+=("$label drifted")
  fi
}

mode="$(setting reflect_mode immediate)"
runner="$(setting reflector_runner default)"
claude_model="$(setting reflector_claude_model "")"
claude_fallback_model="$(setting reflector_claude_fallback_model "")"
codex_model="$(setting reflector_codex_model "")"
hour="$(setting nightly_hour 3)"
minute="$(setting nightly_minute 0)"
needs_repair=0
reasons=()

echo "$(timestamp) healthcheck start mode=$mode runner=$runner"

if [[ "$(readlink "$HOME/.claude/CLAUDE.md" 2>/dev/null || true)" != "$PROMPT" ]]; then
  needs_repair=1
  reasons+=("Claude prompt link drifted")
fi
if [[ "$(readlink "$HOME/.codex/AGENTS.md" 2>/dev/null || true)" != "$PROMPT" ]]; then
  needs_repair=1
  reasons+=("Codex prompt link drifted")
fi

if [[ "$mode" == "off" ]]; then
  if grep -q 'trigger-reflect.sh' "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" 2>/dev/null; then
    needs_repair=1
    reasons+=("hooks still installed while mode=off")
  fi
elif ! grep -q "$REPO/hooks/trigger-reflect.sh" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" 2>/dev/null; then
  needs_repair=1
  reasons+=("trigger hook missing")
fi

scan_label="ai.companion.introspect.codex-scanner"
scan_plist="$HOME/Library/LaunchAgents/$scan_label.plist"
reflector_label="ai.companion.introspect.reflector"
reflector_plist="$HOME/Library/LaunchAgents/$reflector_label.plist"
if [[ "$mode" == "off" ]]; then
  if [[ -f "$scan_plist" ]]; then
    needs_repair=1
    reasons+=("scanner installed while mode=off")
  fi
elif [[ ! -f "$scan_plist" ]] || ! grep -q "$REPO/hooks/codex-transcript-scan.py" "$scan_plist" || ! launchctl print "gui/$(id -u)/$scan_label" >/dev/null 2>&1; then
  needs_repair=1
  reasons+=("Codex scanner missing or unloaded")
else
  check_plist_env "$scan_plist" "INTROSPECT_REFLECT_MODE" "$mode" "scanner reflect mode"
  check_plist_env "$scan_plist" "INTROSPECT_REFLECTOR_RUNNER" "$runner" "scanner runner"
  check_plist_env "$scan_plist" "INTROSPECT_REFLECTOR_CLAUDE_MODEL" "$claude_model" "scanner Claude model"
  check_plist_env "$scan_plist" "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL" "$claude_fallback_model" "scanner Claude fallback model"
  check_plist_env "$scan_plist" "INTROSPECT_REFLECTOR_CODEX_MODEL" "$codex_model" "scanner Codex model"
fi

if [[ "$mode" == "nightly" ]]; then
  if [[ ! -f "$reflector_plist" ]] || ! grep -q "$REPO/hooks/trigger-worker.py" "$reflector_plist" || ! launchctl print "gui/$(id -u)/$reflector_label" >/dev/null 2>&1; then
    needs_repair=1
    reasons+=("nightly reflector missing or unloaded")
  else
    check_plist_env "$reflector_plist" "INTROSPECT_REFLECTOR_RUNNER" "$runner" "nightly runner"
    check_plist_env "$reflector_plist" "INTROSPECT_REFLECTOR_CLAUDE_MODEL" "$claude_model" "nightly Claude model"
    check_plist_env "$reflector_plist" "INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL" "$claude_fallback_model" "nightly Claude fallback model"
    check_plist_env "$reflector_plist" "INTROSPECT_REFLECTOR_CODEX_MODEL" "$codex_model" "nightly Codex model"
  fi
elif [[ -f "$reflector_plist" ]]; then
  needs_repair=1
  reasons+=("nightly reflector installed while mode=$mode")
fi

if [[ "$needs_repair" == "1" ]]; then
  echo "$(timestamp) repair: ${reasons[*]}"
  INTROSPECT_SKIP_MONITOR_BOOTSTRAP=1 "$REPO/scripts/install-hooks.sh" \
    --reflect-mode "$mode" \
    --nightly-hour "$hour" \
    --nightly-minute "$minute" \
    --runner "$runner" \
    --claude-model "$claude_model" \
    --claude-fallback-model "$claude_fallback_model" \
    --codex-model "$codex_model" \
    --home "$INTROSPECT_HOME_DIR" \
    --feedback-dir "$FEEDBACK_DIR"
else
  echo "$(timestamp) no repair needed"
fi

if "$REPO/scripts/introspect-status.sh" >"$LATEST" 2>&1; then
  echo "$(timestamp) status ok -> $LATEST"
else
  code=$?
  echo "$(timestamp) status exited $code -> $LATEST"
  exit "$code"
fi
