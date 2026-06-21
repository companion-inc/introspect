#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

HOME_DIR="$TMPDIR/home"
SOURCE="$HOME_DIR/.introspect/skills"
mkdir -p "$SOURCE/default-skill" "$SOURCE/claude-skill" "$SOURCE/opencode-skill"

cat > "$SOURCE/default-skill/SKILL.md" <<'MD'
---
name: default-skill
description: Default export goes to the agent-compatible global root.
---

# Default Skill
MD

cat > "$SOURCE/claude-skill/SKILL.md" <<'MD'
---
name: claude-skill
description: Claude-only export.
compatibility: claude
---

# Claude Skill
MD

cat > "$SOURCE/opencode-skill/SKILL.md" <<'MD'
---
name: opencode-skill
description: OpenCode-only export.
compatibility: opencode
---

# OpenCode Skill
MD

HOME="$HOME_DIR" INTROSPECT_HOME="$HOME_DIR/.introspect" INTROSPECT_USER_SKILLS_DIR="$SOURCE" "$REPO/scripts/sync-user-skills.sh" >/dev/null

expect_link() {
  local link="$1"
  local target="$2"
  local actual=""
  actual="$(readlink "$link" 2>/dev/null || true)"
  if [[ -z "$actual" || "$(realpath "$actual")" != "$(realpath "$target")" ]]; then
    echo "test-user-skill-sync: expected $link -> $target, got ${actual:-missing}" >&2
    exit 1
  fi
}

expect_absent() {
  local path="$1"
  if [[ -e "$path" || -L "$path" ]]; then
    echo "test-user-skill-sync: expected absent $path" >&2
    exit 1
  fi
}

expect_link "$HOME_DIR/.agents/skills/default-skill" "$SOURCE/default-skill"
expect_absent "$HOME_DIR/.claude/skills/default-skill"
expect_absent "$HOME_DIR/.config/opencode/skills/default-skill"

expect_link "$HOME_DIR/.claude/skills/claude-skill" "$SOURCE/claude-skill"
expect_absent "$HOME_DIR/.agents/skills/claude-skill"
expect_absent "$HOME_DIR/.config/opencode/skills/claude-skill"

expect_link "$HOME_DIR/.config/opencode/skills/opencode-skill" "$SOURCE/opencode-skill"
expect_absent "$HOME_DIR/.agents/skills/opencode-skill"
expect_absent "$HOME_DIR/.claude/skills/opencode-skill"

HOME="$HOME_DIR" INTROSPECT_HOME="$HOME_DIR/.introspect" INTROSPECT_USER_SKILLS_DIR="$SOURCE" "$REPO/scripts/sync-user-skills.sh" --unlink >/dev/null

expect_absent "$HOME_DIR/.agents/skills/default-skill"
expect_absent "$HOME_DIR/.claude/skills/claude-skill"
expect_absent "$HOME_DIR/.config/opencode/skills/opencode-skill"

echo "test-user-skill-sync: ok"
