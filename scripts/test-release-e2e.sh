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
mkdir -p "$HOME_DIR"

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

HOME="$HOME_DIR" \
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

HOME="$HOME_DIR" \
PYTHONDONTWRITEBYTECODE=1 \
INTROSPECT_HOME="$INTROSPECT_HOME_DIR" \
AGENTS_HOME="$AGENTS_HOME_DIR" \
"$APP_BIN" --status > "$TMPDIR/status.txt"
grep -q "private home: $INTROSPECT_HOME_DIR" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+claude prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+codex prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }
grep -Eq "ok[[:space:]]+opencode prompt -> $SOURCE_PROMPT" "$TMPDIR/status.txt" || { cat "$TMPDIR/status.txt" >&2; exit 1; }

mkdir -p "$FEEDBACK_DIR" "$TMPDIR/project"
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
