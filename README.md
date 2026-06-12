# Introspect

Open-source macOS app and hook engine for improving local Claude/Codex agent instructions from real frustration signals.

Bundle identifier:

```text
ai.companion.introspect
```

The public repo contains the app, hooks, worker, scripts, default prompt/skill templates, and docs. A user's private profile lives separately at `~/.introspect/profile` and can be version-controlled locally. That private profile is where user-specific prompts, skills, approved/rejected tripwire words, and feedback state should live.

This checkout still contains Advait's current private prompt while the project is being developed. Before publishing, move private prompt/skill state into the local profile repo and keep this repo to the reusable app/engine.

## Mac App

Build the app:

```bash
./scripts/build-introspect-app.sh
open .build/Introspect.app
```

The app can:

- apply the system prompt links for Claude and Codex
- install hooks in `immediate`, `nightly`, or `off` mode
- remove hooks without deleting the prompt links
- initialize `~/.introspect/profile` as a local Git repo
- edit the exact frustration trigger word list
- show queue, prompt-link, hook, LaunchAgent, and last-run status

## Install

```bash
./scripts/install-hooks.sh --reflect-mode immediate
```

This links:

```text
~/.claude/CLAUDE.md -> ./AGENTS.md
~/.codex/AGENTS.md -> ./AGENTS.md
```

It also installs Claude/Codex `UserPromptSubmit` hooks that run `hooks/frustration-reflect.sh`.

Reflection modes:

- `immediate`: enqueue the event and kick one locked worker after frustration. The worker debounces bursts and applies global/session cooldowns.
- `nightly`: enqueue only; install a LaunchAgent at the configured hour/minute.
- `off`: remove hooks while keeping prompt links available.

The reflector runner defaults to `auto`: use `claude` if only Claude exists, `codex` if only Codex exists, and randomly choose one per batch if both exist. No model is pinned; each CLI uses its own configured default model.

## Verify

```bash
readlink ~/.claude/CLAUDE.md
readlink ~/.codex/AGENTS.md
rg "frustration-reflect.sh" ~/.claude/settings.json ~/.codex/hooks.json
INTROSPECT_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
./scripts/test-frustration-tripwire.py
./scripts/introspect-status.sh
```

## How It Works

1. Claude Code or Codex submits a user prompt.
2. `hooks/frustration-reflect.sh` logs prompt metadata to `feedback/events.jsonl`.
3. The hook uses the exact word list from `~/.introspect/profile/frustration-words.json` when present, otherwise the built-in default list.
4. If the prompt contains an explicit active frustration word, the hook appends it to `feedback/frustration-queue.jsonl`.
5. In immediate mode, the hook kicks `hooks/frustration-worker.py --kick`. In nightly mode, the LaunchAgent runs `hooks/frustration-worker.py --nightly`.
6. The worker holds a lock, batches nearby events, applies cooldowns, and runs at most one reflector process.
7. The reflector inspects the transcript and stats, then chooses one target: `no_change`, `core_prompt`, `skill_new`, `skill_update`, or `skill_prune`.

When a real reflector process starts, the worker also sends a macOS notification titled `Introspect`. Set `INTROSPECT_NOTIFY=0` in the hook environment to disable the popup.

## Files

- `Package.swift` and `Sources/IntrospectApp/`: native macOS menu bar/settings app.
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
- `scripts/build-introspect-app.sh`: builds `.build/Introspect.app`.
- `scripts/validate-skills.py`: validates the skill index and skill files.
- `scripts/test-frustration-tripwire.py`: regression test for the foreground frustration detector.
- `scripts/introspect-status.sh`: health check for links, hooks, skills, queue, and recent reflector runs.
- `feedback/`: ignored local queue, stats, and reflector logs.
