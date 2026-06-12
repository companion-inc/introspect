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
- show discovered global/project agent files and project skills
- initialize a project's `AGENTS.md`, `CLAUDE.md`, `.agents/skills/`, `.claude/skills/`, and `.claude/rules/` surface
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
7. The reflector inspects the transcript and stats, then chooses one target: `no_change`, `core_prompt`, `project_prompt`, `profile_memory`, `skill_new`, `skill_update`, `project_skill_new`, `project_skill_update`, or `skill_prune`.

When a real reflector process starts, the worker also sends a macOS notification titled `Introspect`. Set `INTROSPECT_NOTIFY=0` in the hook environment to disable the popup.

## Agent File Scopes

Introspect treats agent memory as a routing problem, not one giant prompt.

- Global invariants belong in `~/.codex/AGENTS.md` or the linked global Claude/Codex prompt this repo installs.
- Project-wide Codex guidance belongs in the repo's `AGENTS.md`; nested `AGENTS.md` files append narrower instructions, with closer files winning on conflicts.
- `AGENTS.override.md` is different: it replaces the regular `AGENTS.md` at that directory level, so use it only when a subtree should override that layer instead of appending to it.
- Claude reads `CLAUDE.md` / `.claude/CLAUDE.md`, not `AGENTS.md` directly, so project `CLAUDE.md` should import shared guidance with `@AGENTS.md` before Claude-only additions.
- Private project notes belong in `CLAUDE.local.md` and should stay gitignored.
- Project skills belong beside the codebase: `.agents/skills/<skill>/SKILL.md` for Codex-style project skills and `.claude/skills/<skill>/SKILL.md` for Claude project skills.

References used for this hierarchy: [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md), [AGENTS.md](https://agents.md/), [Claude memory](https://code.claude.com/docs/en/memory), and [Claude skills](https://code.claude.com/docs/en/skills).

## Learning Layers

Self-evolution should not mean "append everything to the system prompt."

- System prompt: durable behavior that should shape nearly every task.
- Project prompt: repo-specific facts, decisions, and local working rules.
- Profile memory: durable user preferences, vocabulary, and local machine facts.
- Skills: repeatable procedures, tool workflows, references, scripts, and assets loaded on demand.
- Training/adapters: later behavior work only after enough examples and eval gates exist.

Hermes was reviewed as the main reference for this split. The conclusion is in `docs/hermes-self-evolution-review.md`: use its layered memory/skills/curator shape, but do not copy its eager default skill-writing bias or promote any learned behavior without evals and approval/staging.

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
- `docs/hermes-self-evolution-review.md`: source-backed review of Hermes memory, skill, curator, and training loops.
- `docs/skill-manager-reference-review.md`: source-backed review of public skill-manager apps and self-improvement tools.
- `scripts/install-hooks.sh`: installs/uninstalls prompt links and hooks.
- `scripts/build-introspect-app.sh`: builds `.build/Introspect.app`.
- `scripts/validate-skills.py`: validates the skill index and skill files.
- `scripts/test-frustration-tripwire.py`: regression test for the foreground frustration detector.
- `scripts/introspect-status.sh`: health check for links, hooks, skills, queue, and recent reflector runs.
- `feedback/`: ignored local queue, stats, and reflector logs.
