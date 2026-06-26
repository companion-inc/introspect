#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

HOME_DIR="$TMPDIR/home"
mkdir -p "$HOME_DIR"

expect_link() {
  local link="$1"
  local target="$2"
  local actual=""
  actual="$(readlink "$link" 2>/dev/null || true)"
  if [[ "$actual" != "$target" ]]; then
    echo "test-install-paths: expected $link -> $target, got ${actual:-missing}" >&2
    exit 1
  fi
}

expect_absent() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    echo "test-install-paths: expected absent $path" >&2
    exit 1
  fi
}

HOME="$HOME_DIR" INTROSPECT_SKIP_LAUNCHD=1 "$REPO/scripts/install-hooks.sh" --reflect-mode immediate >/dev/null

INTROSPECT_HOME="$HOME_DIR/.introspect"
SOURCE_PROMPT="$INTROSPECT_HOME/AGENTS.md"
OLD_PUBLIC_PROMPT="$HOME_DIR/.agents/AGENTS.md"

test -d "$INTROSPECT_HOME"
test -d "$INTROSPECT_HOME/.git"
test -f "$INTROSPECT_HOME/AGENTS.md"
cmp "$REPO/templates/default-AGENTS.md" "$INTROSPECT_HOME/AGENTS.md" >/dev/null
if grep -q "Optimize for the user's actual goal" "$INTROSPECT_HOME/AGENTS.md"; then
  echo "test-install-paths: fresh install copied project AGENTS.md instead of the public template" >&2
  exit 1
fi
expect_absent "$OLD_PUBLIC_PROMPT"
expect_link "$HOME_DIR/.claude/CLAUDE.md" "$SOURCE_PROMPT"
expect_link "$HOME_DIR/.codex/AGENTS.md" "$SOURCE_PROMPT"
expect_link "$HOME_DIR/.config/opencode/AGENTS.md" "$SOURCE_PROMPT"
grep -q "PYTHONDONTWRITEBYTECODE=1" "$HOME_DIR/.claude/settings.json"
grep -q "PYTHONDONTWRITEBYTECODE=1" "$HOME_DIR/.codex/hooks.json"
grep -q "INTROSPECT_REFLECTOR_APPLY_MODE=proposal" "$HOME_DIR/.claude/settings.json"
grep -q "INTROSPECT_REFLECTOR_APPLY_MODE=proposal" "$HOME_DIR/.codex/hooks.json"
grep -q "/usr/bin/python3 .*hooks/trigger-reflect.sh" "$HOME_DIR/.claude/settings.json"
grep -q "/usr/bin/python3 .*hooks/trigger-reflect.sh" "$HOME_DIR/.codex/hooks.json"
/usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "/usr/bin/python3"
/usr/libexec/PlistBuddy -c "Print :ProgramArguments:1" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -q "/hooks/codex-transcript-scan.py"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PYTHONDONTWRITEBYTECODE" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "1"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:INTROSPECT_REFLECTOR_APPLY_MODE" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "proposal"
/usr/libexec/PlistBuddy -c "Print :StartInterval" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "60"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:PYTHONDONTWRITEBYTECODE" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.health.plist" | grep -qx "1"
if /usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:INTROSPECT_ASSISTANT_FAILURE_MODEL" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" >/dev/null 2>&1; then
  echo "test-install-paths: scanner should not install assistant-message wake model env" >&2
  exit 1
fi
test ! -f "$HOME_DIR/.introspect/models/assistant-boundary-logreg-v1.json"
grep -q "$HOME_DIR/.codex/sessions" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist"
grep -q "$HOME_DIR/.claude/projects" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist"

HOME="$HOME_DIR" INTROSPECT_SKIP_LAUNCHD=1 "$REPO/bin/introspect" config --runner codex --sensitivity sensitive --apply-mode auto >/dev/null
grep -q "INTROSPECT_REFLECTOR_APPLY_MODE=auto" "$HOME_DIR/.claude/settings.json"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:INTROSPECT_REFLECTOR_APPLY_MODE" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "auto"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:INTROSPECT_REFLECTOR_RUNNER" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "codex"
/usr/libexec/PlistBuddy -c "Print :EnvironmentVariables:INTROSPECT_WAKE_SENSITIVITY" "$HOME_DIR/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist" | grep -qx "sensitive"

HOME="$HOME_DIR" INTROSPECT_SKIP_LAUNCHD=1 "$REPO/scripts/install-hooks.sh" --uninstall >/dev/null

expect_absent "$OLD_PUBLIC_PROMPT"
expect_absent "$HOME_DIR/.claude/CLAUDE.md"
expect_absent "$HOME_DIR/.codex/AGENTS.md"
expect_absent "$HOME_DIR/.config/opencode/AGENTS.md"
test -d "$INTROSPECT_HOME"

MIGRATE_HOME="$TMPDIR/migrate-home"
mkdir -p "$MIGRATE_HOME/.agents/introspect"
printf '# migrated prompt\n' > "$MIGRATE_HOME/.agents/introspect/AGENTS.md"
ln -s "$MIGRATE_HOME/.agents/introspect/AGENTS.md" "$MIGRATE_HOME/.agents/AGENTS.md"

HOME="$MIGRATE_HOME" INTROSPECT_SKIP_LAUNCHD=1 "$REPO/scripts/install-hooks.sh" --reflect-mode immediate >/dev/null

MIGRATED_HOME_DIR="$MIGRATE_HOME/.introspect"
MIGRATED_PROMPT="$MIGRATED_HOME_DIR/AGENTS.md"
test -d "$MIGRATED_HOME_DIR"
test ! -e "$MIGRATE_HOME/.agents/introspect"
grep -q "# migrated prompt" "$MIGRATED_PROMPT"
expect_absent "$MIGRATE_HOME/.agents/AGENTS.md"
expect_link "$MIGRATE_HOME/.claude/CLAUDE.md" "$MIGRATED_PROMPT"
expect_link "$MIGRATE_HOME/.codex/AGENTS.md" "$MIGRATED_PROMPT"
expect_link "$MIGRATE_HOME/.config/opencode/AGENTS.md" "$MIGRATED_PROMPT"

echo "test-install-paths: ok"
