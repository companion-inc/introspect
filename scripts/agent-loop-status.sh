#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FEEDBACK_DIR="${AGENTS_MD_FEEDBACK_DIR:-$REPO/feedback}"
LAUNCH_LABEL="com.advait.agent-loop.reflector"
LAUNCH_PLIST="$HOME/Library/LaunchAgents/$LAUNCH_LABEL.plist"

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
  if [[ -f "$path" ]] && grep -q "$REPO/hooks/frustration-reflect.sh" "$path"; then
    printf "ok   %s hook installed\n" "$label"
  else
    printf "bad  %s hook missing from %s\n" "$label" "$path"
  fi
}

cd "$REPO"
printf "agent-loop status\n"
printf "repo: %s\n" "$REPO"
printf "commit: "
git rev-parse --short HEAD

check_link "claude prompt" "$HOME/.claude/CLAUDE.md" "$REPO/AGENTS.md"
check_link "codex prompt" "$HOME/.codex/AGENTS.md" "$REPO/AGENTS.md"
check_hook "claude" "$HOME/.claude/settings.json"
check_hook "codex" "$HOME/.codex/hooks.json"
if grep -q "AGENT_LOOP_REFLECT_MODE=nightly" "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" 2>/dev/null; then
  printf "ok   foreground hooks queue for nightly reflection\n"
else
  printf "warn foreground hook mode not explicitly nightly\n"
fi
if [[ -f "$LAUNCH_PLIST" ]] && grep -q "$REPO/hooks/frustration-worker.py" "$LAUNCH_PLIST"; then
  printf "ok   nightly LaunchAgent installed -> %s\n" "$LAUNCH_PLIST"
else
  printf "bad  nightly LaunchAgent missing -> %s\n" "$LAUNCH_PLIST"
fi
if [[ -f "$LAUNCH_PLIST" ]]; then
  runner="$(python3 - "$LAUNCH_PLIST" <<'PY'
import plistlib
import sys
from pathlib import Path

data = plistlib.loads(Path(sys.argv[1]).read_bytes())
env = data.get("EnvironmentVariables", {})
print(env.get("AGENT_LOOP_REFLECTOR_RUNNER", "auto"))
PY
)"
  claude_path="$(command -v claude || true)"
  codex_path="$(command -v codex || true)"
  printf "ok   reflector runner=%s" "$runner"
  if [[ -n "$claude_path" && -n "$codex_path" && "$runner" == "auto" ]]; then
    printf " (claude+codex found; nightly batch randomly chooses one)"
  elif [[ -n "$claude_path" || -n "$codex_path" ]]; then
    printf " (found:%s%s)" "${claude_path:+ claude}" "${codex_path:+ codex}"
  fi
  printf "\n"
fi
if [[ "${AGENT_LOOP_NOTIFY:-1}" == "0" || "${AGENTS_MD_NOTIFY:-1}" == "0" ]]; then
  printf "off  macOS spawn notifications disabled by env\n"
else
  printf "ok   macOS spawn notifications enabled\n"
fi

printf "\nskills:\n"
"$REPO/scripts/validate-skills.py"

printf "\nfeedback:\n"
if [[ -f "$FEEDBACK_DIR/events.jsonl" ]]; then
  python3 - "$FEEDBACK_DIR" <<'PY'
import ast
import json
import re
import sys
from collections import Counter
from pathlib import Path

feedback = Path(sys.argv[1])
repo = feedback.parent
active_words = None
hook_text = (repo / "hooks" / "frustration-reflect.sh").read_text()
match = re.search(r"BAD_WORDS = (\{.*?\})", hook_text, flags=re.S)
if match:
    active_words = set(ast.literal_eval(match.group(1)))

events = []
for line in (feedback / "events.jsonl").read_text().splitlines():
    try:
        events.append(json.loads(line))
    except Exception:
        pass

frustrated = [event for event in events if event.get("frustrated")]
print(f"events: {len(events)} total, {len(frustrated)} frustrated")
if events:
    print(f"latest event: {events[-1].get('ts')} frustrated={events[-1].get('frustrated')}")
if frustrated:
    words = Counter(
        word
        for event in frustrated
        for word in event.get("matched", [])
        if active_words is None or word in active_words
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

queue_path = feedback / "frustration-queue.jsonl"
if queue_path.exists():
    queued = sum(1 for line in queue_path.read_text().splitlines() if line.strip())
else:
    queued = 0
print(f"queued events: {queued}")
print(f"lock present: {(feedback / 'reflector.lock').exists()}")
PY
else
  printf "events: none yet\n"
fi

printf "\nrecent reflector log:\n"
tail -n 12 "$FEEDBACK_DIR/reflector.log" 2>/dev/null || printf "no reflector log yet\n"
