# agent-loop

Private one-repo setup for this machine's Claude/Codex agent instructions and feedback loop.

This repo contains both pieces:

- `AGENTS.md` and `skills/`: the real private instructions.
- `hooks/` and `scripts/`: the feedback loop that logs frustration signals, batches them, and routes improvements into the prompt or skills.

It should stay private because it contains personal operating instructions, local feedback logs, and prompt history.

## Install

```bash
./scripts/install-hooks.sh
```

This links:

```text
~/.claude/CLAUDE.md -> ./AGENTS.md
~/.codex/AGENTS.md -> ./AGENTS.md
```

It also installs Claude/Codex `UserPromptSubmit` hooks that run `hooks/frustration-reflect.sh`.

## Verify

```bash
readlink ~/.claude/CLAUDE.md
readlink ~/.codex/AGENTS.md
rg "frustration-reflect.sh" ~/.claude/settings.json ~/.codex/hooks.json
AGENTS_MD_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
./scripts/test-frustration-tripwire.py
./scripts/agent-loop-status.sh
```

## How It Works

1. Claude Code or Codex submits a user prompt.
2. `hooks/frustration-reflect.sh` logs prompt metadata to `feedback/events.jsonl`.
3. If the prompt contains an explicit frustration word, the hook appends it to `feedback/frustration-queue.jsonl`.
4. `hooks/frustration-worker.py` debounces bursts, holds a lock, applies cooldowns, and runs at most one reflector process.
5. The reflector inspects the transcript and stats, then chooses one target: `no_change`, `core_prompt`, `skill_new`, `skill_update`, or `skill_prune`.

When a real reflector process starts, the worker also sends a macOS notification titled `agent-loop`. Set `AGENT_LOOP_NOTIFY=0` or `AGENTS_MD_NOTIFY=0` in the hook environment to disable the popup.

## Files

- `AGENTS.md`: live prompt loaded by Claude and Codex.
- `skills/index.json`: skill routing index.
- `skills/*/SKILL.md`: scoped skill files.
- `skills/agent-md-creator/SKILL.md`: edits the always-loaded AGENTS.md / CLAUDE.md prompt.
- `skills/skill-creator/SKILL.md`: creates, updates, prunes, and validates scoped skills.
- `hooks/frustration-reflect.sh`: prompt hook entrypoint.
- `hooks/frustration-worker.py`: locked background batch worker.
- `hooks/frustration-stats.sh`: feedback scoreboard by prompt commit.
- `docs/frustration-tripwires.md`: human-readable list of active and ignored tripwire words.
- `scripts/install-hooks.sh`: installs/uninstalls prompt links and hooks.
- `scripts/validate-skills.py`: validates the skill index and skill files.
- `scripts/test-frustration-tripwire.py`: regression test for the foreground frustration detector.
- `scripts/agent-loop-status.sh`: health check for links, hooks, skills, queue, and recent reflector runs.
- `feedback/`: ignored local queue, stats, and reflector logs.
