#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FEEDBACK_DIR="${INTROSPECT_FEEDBACK_DIR:-$REPO/feedback}"
INTROSPECT_HOME_DIR="${INTROSPECT_HOME:-$HOME/.introspect}"
HOME_SETTINGS="$INTROSPECT_HOME_DIR/settings.json"
BUILT_NOTIFICATION_HELPER="$REPO/.build/Introspect.app/Contents/MacOS/Introspect"
INSTALLED_NOTIFICATION_HELPER="/Applications/Introspect.app/Contents/MacOS/Introspect"
NOTIFICATION_HELPER="$BUILT_NOTIFICATION_HELPER"
if [[ -x "$INSTALLED_NOTIFICATION_HELPER" ]]; then
  NOTIFICATION_HELPER="$INSTALLED_NOTIFICATION_HELPER"
fi
LAUNCH_LABEL="ai.companion.introspect.reflector"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"
SCAN_LABEL="ai.companion.introspect.codex-scanner"
SCAN_PLIST="$HOME/Library/LaunchAgents/$SCAN_LABEL.plist"
MONITOR_LABEL="ai.companion.introspect.health"
MONITOR_PLIST="$HOME/Library/LaunchAgents/$MONITOR_LABEL.plist"

check_link() {
  local label="$1"
  local link="$2"
  local expected="$3"
  local actual=""
  actual="$(readlink "$link" 2>/dev/null || true)"
  if [[ "$actual" == "$expected" ]]; then
    printf "ok   %s -> %s\n" "$label" "$actual"
  else
    printf "bad  %s -> %s (expected %s)\n" "$label" "${actual:-missing}" "$expected"
  fi
}

check_hook() {
  local label="$1"
  local path="$2"
  if [[ -f "$path" ]] && grep -q "$REPO/hooks/trigger-reflect.sh" "$path"; then
    printf "ok   %s hook installed\n" "$label"
  else
    printf "bad  %s hook missing from %s\n" "$label" "$path"
  fi
}

reflector_env_summary() {
  local plist="$1"
  python3 - "$plist" <<'PY'
import plistlib
import sys
from pathlib import Path

data = plistlib.loads(Path(sys.argv[1]).read_bytes())
env = data.get("EnvironmentVariables", {})

def value(name, default=""):
    raw = env.get(name, default)
    return raw if isinstance(raw, str) else default

def model(raw):
    cleaned = raw.strip()
    return cleaned if cleaned else "CLI default"

runner = value("INTROSPECT_REFLECTOR_RUNNER", "default")
claude = model(value("INTROSPECT_REFLECTOR_CLAUDE_MODEL"))
fallback = model(value("INTROSPECT_REFLECTOR_CLAUDE_FALLBACK_MODEL"))
codex = model(value("INTROSPECT_REFLECTOR_CODEX_MODEL"))
shadow = value("INTROSPECT_WAKE_SHADOW_MODELS")
shadow_count = len([item for item in shadow.split(",") if item.strip()])
sensitivity = value("INTROSPECT_WAKE_SENSITIVITY", "balanced")
threshold = value("INTROSPECT_WAKE_THRESHOLD")
threshold_text = threshold.strip() if threshold.strip() else "model"
print(
    f"runner={runner} claude_model={claude} claude_fallback={fallback} "
    f"codex_model={codex} sensitivity={sensitivity} threshold={threshold_text} "
    f"shadow_models={shadow_count}"
)
PY
}

cd "$REPO"
printf "Introspect status\n"
printf "repo: %s\n" "$REPO"
printf "commit: "
git rev-parse --short HEAD

check_link "claude prompt" "$HOME/.claude/CLAUDE.md" "$INTROSPECT_HOME_DIR/AGENTS.md"
check_link "codex prompt" "$HOME/.codex/AGENTS.md" "$INTROSPECT_HOME_DIR/AGENTS.md"
check_hook "claude" "$HOME/.claude/settings.json"
check_hook "codex" "$HOME/.codex/hooks.json"
mode="$(python3 - "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import re
import sys
from pathlib import Path

for raw in sys.argv[1:]:
    path = Path(raw)
    if not path.exists():
        continue
    try:
        data = json.loads(path.read_text())
    except Exception:
        continue
    groups = data.get("hooks", {}).get("UserPromptSubmit", [])
    for group in groups if isinstance(groups, list) else []:
        for hook in group.get("hooks", []) if isinstance(group, dict) else []:
            command = hook.get("command") if isinstance(hook, dict) else ""
            if "trigger-reflect.sh" not in command:
                continue
            match = re.search(r"INTROSPECT_REFLECT_MODE=([^ ]+)", command)
            print(match.group(1) if match else "immediate")
            raise SystemExit(0)
print("off")
PY
)"
if [[ "$mode" == "immediate" ]]; then
  printf "ok   foreground hooks kick locked worker after trigger\n"
elif [[ "$mode" == "nightly" ]]; then
  printf "ok   foreground hooks queue for nightly reflection\n"
elif [[ "$mode" == "off" ]]; then
  printf "off  foreground hooks disabled\n"
else
  printf "warn unknown reflector mode: %s\n" "$mode"
fi
if [[ "$mode" == "nightly" ]]; then
  if [[ -f "$LAUNCH_PLIST" ]] && grep -q "$REPO/hooks/trigger-worker.py" "$LAUNCH_PLIST"; then
    printf "ok   nightly LaunchAgent installed -> %s\n" "$LAUNCH_PLIST"
  else
    printf "bad  nightly LaunchAgent missing -> %s\n" "$LAUNCH_PLIST"
  fi
elif [[ -f "$LAUNCH_PLIST" ]]; then
  printf "warn nightly LaunchAgent installed while mode=%s -> %s\n" "$mode" "$LAUNCH_PLIST"
else
  printf "ok   nightly LaunchAgent not installed for mode=%s\n" "$mode"
fi
if [[ "$mode" == "off" ]]; then
  if [[ -f "$SCAN_PLIST" ]]; then
    printf "warn Codex transcript scanner installed while mode=off -> %s\n" "$SCAN_PLIST"
  else
    printf "off  Codex transcript scanner disabled\n"
  fi
elif [[ -f "$SCAN_PLIST" ]] && grep -q "$REPO/hooks/codex-transcript-scan.py" "$SCAN_PLIST"; then
  if launchctl print "gui/$(id -u)/$SCAN_LABEL" >/dev/null 2>&1; then
    printf "ok   Codex transcript scanner loaded -> %s\n" "$SCAN_PLIST"
  else
    printf "warn Codex transcript scanner installed but not loaded -> %s\n" "$SCAN_PLIST"
  fi
  scan_env="$(reflector_env_summary "$SCAN_PLIST")"
  printf "ok   scanner reflector %s" "$scan_env"
  if [[ "$scan_env" == runner=default* ]]; then
    printf " (most-used installed agent; no random selection)"
  fi
  printf "\n"
else
  printf "bad  Codex transcript scanner missing -> %s\n" "$SCAN_PLIST"
fi
if [[ -f "$MONITOR_PLIST" ]] && grep -q "$REPO/scripts/introspect-healthcheck.sh" "$MONITOR_PLIST"; then
  if launchctl print "gui/$(id -u)/$MONITOR_LABEL" >/dev/null 2>&1; then
    printf "ok   health monitor loaded -> %s\n" "$MONITOR_PLIST"
  else
    printf "warn health monitor installed but not loaded -> %s\n" "$MONITOR_PLIST"
  fi
else
  printf "bad  health monitor missing -> %s\n" "$MONITOR_PLIST"
fi
if [[ -f "$LAUNCH_PLIST" ]]; then
  runner_env="$(reflector_env_summary "$LAUNCH_PLIST")"
  claude_path="$(command -v claude || true)"
  codex_path="$(command -v codex || true)"
  printf "ok   nightly reflector %s" "$runner_env"
  if [[ -n "$claude_path" && -n "$codex_path" && "$runner_env" == runner=default* ]]; then
    printf " (claude+codex found; most-used installed agent wins)"
  elif [[ -n "$claude_path" || -n "$codex_path" ]]; then
    printf " (found:%s%s)" "${claude_path:+ claude}" "${codex_path:+ codex}"
  fi
  printf "\n"
fi
notify_setting="$(python3 - "$HOME_SETTINGS" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    print("enabled")
    raise SystemExit(0)
if isinstance(data, dict) and data.get("notifications_enabled") is False:
    print("disabled")
else:
    print("enabled")
PY
)"
if [[ "${INTROSPECT_NOTIFY:-1}" == "0" ]]; then
  printf "off  reflector notifications disabled by env\n"
elif [[ "$notify_setting" == "disabled" ]]; then
  printf "off  reflector notifications disabled in %s\n" "$HOME_SETTINGS"
else
  printf "ok   reflector notifications enabled in %s\n" "$HOME_SETTINGS"
fi
if [[ -x "$NOTIFICATION_HELPER" ]]; then
  helper_status="$("$NOTIFICATION_HELPER" --notification-status 2>/dev/null | head -n 1 || true)"
  case "$helper_status" in
    "allowed by macOS"|"delivered quietly by macOS"|"temporarily allowed by macOS")
      printf "ok   notifications post through Introspect.app -> %s\n" "$NOTIFICATION_HELPER"
      ;;
    "not requested yet")
      printf "warn Introspect.app notification permission not requested yet -> %s\n" "$NOTIFICATION_HELPER"
      ;;
    *)
      printf "warn Introspect.app notification helper blocked by macOS (%s)\n" "${helper_status:-unknown}"
      ;;
  esac
else
  printf "warn Introspect.app notification helper missing\n"
fi

printf "\nskills:\n"
"$REPO/scripts/validate-skills.py"

printf "\nfeedback:\n"
if [[ -f "$FEEDBACK_DIR/events.jsonl" ]]; then
  python3 - "$FEEDBACK_DIR" "$INTROSPECT_HOME_DIR" <<'PY'
import json
import re
import sys
from collections import Counter
from pathlib import Path

feedback = Path(sys.argv[1])
home = Path(sys.argv[2])
repo = feedback.parent
active_words = set()
words_file = home / "trigger-words.txt"
if words_file.exists():
    active_words = {
        line.strip().lower()
        for line in words_file.read_text().splitlines()
        if re.fullmatch(r"[a-z]+", line.strip().lower())
    }

events = []
for line in (feedback / "events.jsonl").read_text().splitlines():
    try:
        events.append(json.loads(line))
    except Exception:
        pass

triggered = [event for event in events if event.get("triggered")]
print(f"events: {len(events)} total, {len(triggered)} triggered")
classifier_events = [
    event
    for event in events
    if isinstance(event.get("classifier"), dict) and "score" in event["classifier"]
]
sensitivities = sorted(
    {
        str(event["classifier"].get("wake_sensitivity"))
        for event in classifier_events
        if event["classifier"].get("wake_sensitivity")
    }
)
shadow_events = [
    event
    for event in classifier_events
    if event["classifier"].get("alternates")
]
shadow_models = sorted(
    {
        str(alternate.get("name"))
        for event in shadow_events
        for alternate in event["classifier"].get("alternates", [])
        if alternate.get("name")
    }
)
shadow_backfilled = sum(1 for event in shadow_events if event["classifier"].get("alternates_backfilled_at"))
print(
    "classifier: "
    f"{len(classifier_events)} scored, "
    f"{len(shadow_events)} shadow-scored, "
    f"{shadow_backfilled} backfilled, "
    f"{len(shadow_models)} candidate model(s), "
    f"sensitivities={','.join(sensitivities) if sensitivities else 'unknown'}"
)
if events:
    print(f"latest event: {events[-1].get('ts')} triggered={events[-1].get('triggered')}")
if triggered:
    words = Counter(
        word
        for event in triggered
        for word in event.get("matched", [])
        if word in active_words
    )
    if words:
        print("top active matches: " + ", ".join(f"{word}={count}" for word, count in words.most_common(8)))

batches_path = feedback / "reflector-batches.jsonl"
if batches_path.exists():
    batches = []
    for line in batches_path.read_text().splitlines():
        try:
            batches.append(json.loads(line))
        except Exception:
            pass
    if batches:
        last = batches[-1]
        print(f"latest batch: {last.get('ts')} events={last.get('event_count')} dry_run={last.get('dry_run')}")

state_path = feedback / "reflector-state.json"
if state_path.exists():
    state = json.loads(state_path.read_text())
    print(f"last run: {state.get('last_run_at')}")
    print(f"scheduled retry: {state.get('scheduled_retry_at')}")

queue_path = feedback / "trigger-queue.jsonl"
if queue_path.exists():
    queued = sum(1 for line in queue_path.read_text().splitlines() if line.strip())
else:
    queued = 0
print(f"queued events: {queued}")
print(f"lock present: {(feedback / 'reflector.lock').exists()}")

scan_state_path = feedback / "codex-transcript-scan-state.json"
scan_state = {}
if scan_state_path.exists():
    scan_state = json.loads(scan_state_path.read_text())
    print(
        "codex scanner: "
        f"last_scan={scan_state.get('last_scan_at')} "
        f"new={scan_state.get('last_new_events')} "
        f"triggered={scan_state.get('last_triggered_events')}"
    )
else:
    print("codex scanner: never ran")

def parse_ts(value):
    if not value:
        return None
    try:
        return __import__("datetime").datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except Exception:
        return None

def prompt_text(content):
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict) and isinstance(item.get("text"), str):
            parts.append(item["text"])
    return "\n".join(parts)

def is_control(prompt):
    stripped = prompt.lstrip()
    return (
        stripped.startswith("# AGENTS.md instructions for ")
        or stripped.startswith("<codex_internal_context ")
        or stripped.startswith("<turn_aborted>")
        or stripped.startswith("You are the Introspect trigger reflector.")
    )

latest_codex = None
sessions_dir = Path.home() / ".codex" / "sessions"
if sessions_dir.exists():
    cutoff = __import__("time").time() - 24 * 60 * 60
    for path in sessions_dir.rglob("rollout-*.jsonl"):
        try:
            if path.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for line_no, line in enumerate(lines, 1):
            try:
                row = json.loads(line)
            except Exception:
                continue
            payload = row.get("payload")
            if row.get("type") != "response_item" or not isinstance(payload, dict):
                continue
            if payload.get("type") != "message" or payload.get("role") != "user":
                continue
            text = prompt_text(payload.get("content"))
            if not text or is_control(text):
                continue
            ts = parse_ts(row.get("timestamp"))
            if ts and (latest_codex is None or ts > latest_codex[0]):
                latest_codex = (ts, path, line_no)

if latest_codex:
    print(f"latest Codex user message: {latest_codex[0].isoformat(timespec='seconds')} ({latest_codex[1].name})")
    processed_latest = next(
        (
            event
            for event in reversed(events)
            if event.get("source") == "codex_transcript_scan"
            and event.get("transcript_path") == str(latest_codex[1])
            and event.get("transcript_line") == latest_codex[2]
        ),
        None,
    )
    if processed_latest:
        print(f"ok   latest Codex message processed by scanner triggered={processed_latest.get('triggered')}")
        raise SystemExit(0)
    latest_event_ts = parse_ts(events[-1].get("ts")) if events else None
    latest_scan_ts = parse_ts(scan_state.get("last_scan_at"))
    if latest_event_ts and latest_codex[0] > latest_event_ts:
        delta = (latest_codex[0] - latest_event_ts).total_seconds()
        if latest_scan_ts and latest_scan_ts >= latest_codex[0]:
            print(f"warn Codex transcript is {delta:.0f}s newer than feedback after scanner ran")
        else:
            print(f"ok   latest Codex message is pending the next 60s scanner pass ({delta:.0f}s newer than feedback)")
PY
else
  printf "events: none yet\n"
fi

printf "\nrecent reflector log:\n"
tail -n 12 "$FEEDBACK_DIR/reflector.log" 2>/dev/null || printf "no reflector log yet\n"
