#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_BIN="${INTROSPECT_APP_BIN:-$REPO/.build/Introspect.app/Contents/MacOS/Introspect}"
APP_RESOURCES="$(cd "$(dirname "$APP_BIN")/../Resources" && pwd -P)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

HOME_DIR="$TMPDIR/home"
INTROSPECT_HOME_DIR="$HOME_DIR/.introspect"
AGENTS_HOME_DIR="$HOME_DIR/.agents"
FEEDBACK_DIR="$INTROSPECT_HOME_DIR/feedback"
mkdir -p "$HOME_DIR" "$TMPDIR/project"

expect_link() {
  local link="$1"
  local target="$2"
  local actual=""
  actual="$(readlink "$link" 2>/dev/null || true)"
  if [[ "$actual" != "$target" ]]; then
    echo "test-release-e2e: expected $link -> $target, got ${actual:-missing}" >&2
    exit 1
  fi
}

expect_absent() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    echo "test-release-e2e: expected absent $path" >&2
    exit 1
  fi
}

if [[ ! -x "$APP_BIN" ]]; then
  echo "test-release-e2e: missing executable app binary: $APP_BIN" >&2
  exit 1
fi
if [[ ! -f "$APP_RESOURCES/templates/default-AGENTS.md" ]]; then
  echo "test-release-e2e: app bundle missing default prompt template" >&2
  exit 1
fi
if [[ -e "$APP_RESOURCES/AGENTS.md" ]]; then
  echo "test-release-e2e: app bundle contains project AGENTS.md" >&2
  exit 1
fi
if find "$APP_RESOURCES" \( -name '__pycache__' -o -name '*.pyc' -o -name '*.pyo' \) -print -quit | grep -q .; then
  echo "test-release-e2e: app bundle contains generated Python cache files" >&2
  exit 1
fi

SESSION_DIR="$HOME_DIR/.codex/sessions/2026/06/20"
SESSION_FILE="$SESSION_DIR/rollout-2026-06-20T00-00-00-release-backfill.jsonl"
CLAUDE_SESSION_DIR="$HOME_DIR/.claude/projects/release-project"
CLAUDE_SESSION_FILE="$CLAUDE_SESSION_DIR/release-backfill-claude.jsonl"
SESSION_TS="$(date -u "+%Y-%m-%dT%H:%M:%S.000Z")"
mkdir -p "$SESSION_DIR" "$CLAUDE_SESSION_DIR"
cat > "$SESSION_FILE" <<JSONL
{"timestamp":"$SESSION_TS","type":"session_meta","payload":{"id":"release-backfill-session","cwd":"$TMPDIR/project"}}
{"timestamp":"$SESSION_TS","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"release backfill plain history prompt"}]}}
{"timestamp":"$SESSION_TS","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"you did not test the release backfill after I asked you to test it"}]}}
{"timestamp":"$SESSION_TS","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"I’m not continuing until you stop insulting me."}]}}
JSONL
cat > "$CLAUDE_SESSION_FILE" <<JSONL
{"timestamp":"$SESSION_TS","type":"user","sessionId":"release-claude-backfill","message":{"role":"user","content":"release claude backfill prompt"}}
JSONL

HOME="$HOME_DIR" \
GIT_CONFIG_GLOBAL="$TMPDIR/missing-global-gitconfig" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
INTROSPECT_SKIP_LAUNCHD=1 \
"$APP_BIN" --install >/dev/null

SOURCE_PROMPT="$INTROSPECT_HOME_DIR/AGENTS.md"
test -d "$INTROSPECT_HOME_DIR"
cmp "$APP_RESOURCES/templates/default-AGENTS.md" "$SOURCE_PROMPT" >/dev/null
expect_absent "$AGENTS_HOME_DIR/AGENTS.md"
expect_link "$HOME_DIR/.claude/CLAUDE.md" "$SOURCE_PROMPT"
expect_link "$HOME_DIR/.codex/AGENTS.md" "$SOURCE_PROMPT"
expect_link "$HOME_DIR/.config/opencode/AGENTS.md" "$SOURCE_PROMPT"
HOME_PROMPT_VERSION="$(git -C "$INTROSPECT_HOME_DIR" rev-parse --short HEAD)"
python3 - "$FEEDBACK_DIR/events.jsonl" "$FEEDBACK_DIR/trigger-queue.jsonl" "$HOME_PROMPT_VERSION" <<'PY'
import json
import sys
from pathlib import Path

events_path = Path(sys.argv[1])
queue_path = Path(sys.argv[2])
expected_version = sys.argv[3]
events = [json.loads(line) for line in events_path.read_text().splitlines() if line.strip()]
backfilled = [event for event in events if event.get("backfilled")]
if len(backfilled) != 4:
    raise SystemExit(f"test-release-e2e: expected 4 backfilled events, got {len(backfilled)}")
versions = {event.get("version") for event in backfilled}
if versions != {expected_version}:
    raise SystemExit(f"test-release-e2e: expected prompt version {expected_version}, got {versions}")
sources = {event.get("source") for event in backfilled}
if "claude_transcript_backfill" not in sources or "codex_transcript_backfill" not in sources:
    raise SystemExit(f"test-release-e2e: missing backfill source coverage: {sorted(sources)}")
if queue_path.exists() and queue_path.read_text().strip():
    raise SystemExit("test-release-e2e: backfill queued old history into reflector")
PY

HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
INTROSPECT_SKIP_LAUNCHD=1 \
"$APP_BIN" --install > "$TMPDIR/reinstall.txt"
grep -q "skip: initial local agent history backfill already completed" "$TMPDIR/reinstall.txt" || { cat "$TMPDIR/reinstall.txt" >&2; exit 1; }
python3 - "$FEEDBACK_DIR/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

events = [json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines() if line.strip()]
backfilled = [event for event in events if event.get("backfilled")]
if len(backfilled) != 4:
    raise SystemExit(f"test-release-e2e: second install changed backfill count to {len(backfilled)}")
PY

python3 - "$FEEDBACK_DIR/codex-transcript-scan-state.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
state = json.loads(path.read_text())
state["last_backfill_schema_version"] = 1
path.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
PY
HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
INTROSPECT_SKIP_LAUNCHD=1 \
"$APP_BIN" --install > "$TMPDIR/schema-reinstall.txt"
if grep -q "skip: initial local agent history backfill already completed" "$TMPDIR/schema-reinstall.txt"; then
  cat "$TMPDIR/schema-reinstall.txt" >&2
  exit 1
fi
python3 - "$FEEDBACK_DIR/codex-transcript-scan-state.json" "$FEEDBACK_DIR/events.jsonl" <<'PY'
import json
import sys
from pathlib import Path

state = json.loads(Path(sys.argv[1]).read_text())
events = [json.loads(line) for line in Path(sys.argv[2]).read_text().splitlines() if line.strip()]
if state.get("last_backfill_schema_version") != 4:
    raise SystemExit(f"test-release-e2e: schema reinstall did not update version: {state}")
if len([event for event in events if event.get("backfilled")]) != 4:
    raise SystemExit("test-release-e2e: schema reinstall duplicated backfilled events")
PY

HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
"$APP_BIN" --status > "$TMPDIR/status.txt"
grep -q "private home: $INTROSPECT_HOME_DIR" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+claude prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+codex prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+opencode prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -q "history backfill: " "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }

mkdir -p "$FEEDBACK_DIR"
cat > "$FEEDBACK_DIR/trigger-queue.jsonl" <<JSONL
{"triggered":true,"ts":"2026-06-20T00:00:00+00:00","source":"release-e2e","session_id":"release-e2e","cwd":"$TMPDIR/project","matched":["release"],"snippet":"release e2e fake wake event"}
JSONL

HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
INTROSPECT_REPO="$APP_RESOURCES" \
INTROSPECT_FEEDBACK_DIR="$FEEDBACK_DIR" \
TRIGGER_REFLECTOR_DRY_RUN=1 \
TRIGGER_DEBOUNCE_SECONDS=0 \
TRIGGER_COOLDOWN_SECONDS=0 \
INTROSPECT_NOTIFY=0 \
python3 "$APP_RESOURCES/hooks/trigger-worker.py" --kick

grep -q '"dry_run": true' "$FEEDBACK_DIR/reflector-batches.jsonl"
grep -q 'release e2e fake wake event' "$FEEDBACK_DIR/last-reflector-prompt.md"
if grep -q 'read-codex''-threads' "$FEEDBACK_DIR/last-reflector-prompt.md"; then
  echo "test-release-e2e: reflector prompt contains a private Codex thread resolver path" >&2
  exit 1
fi

HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
INTROSPECT_SKIP_LAUNCHD=1 \
"$APP_BIN" --uninstall >/dev/null

expect_absent "$HOME_DIR/.claude/CLAUDE.md"
expect_absent "$HOME_DIR/.codex/AGENTS.md"
expect_absent "$HOME_DIR/.config/opencode/AGENTS.md"
test -d "$INTROSPECT_HOME_DIR"

echo "test-release-e2e: ok"
