# Introspect

Open-source macOS app and hook engine for improving local Claude/Codex agent instructions from real trigger signals.

Bundle identifier:

```text
ai.companion.introspect
```

The public repo contains the app, hooks, worker, scripts, default prompt/skill templates, and docs. User-specific prompt, skill, trigger-word, memory, and run state lives in the private Git repo at `~/.introspect`.

This checkout is the reusable app/engine. The live user-wide prompt is `~/.introspect/AGENTS.md`, which the installer symlinks into Claude and Codex.

## Mac App

Build the app:

```bash
./scripts/build-introspect-app.sh
open .build/Introspect.app
```

The app can:

- apply the system prompt links for Claude and Codex
- install hooks in `immediate`, `nightly`, or `off` mode
- install the Codex transcript scanner backstop for Desktop sessions whose hooks have not fired
- install a recurring health monitor that verifies links, hooks, scanner state, and repairs drift
- remove hooks without deleting the prompt links
- initialize `~/.introspect` as a local Git repo
- show discovered global/project agent files and project skills
- initialize a project's `AGENTS.md`, symlinked `CLAUDE.md`, `.agents/skills/`, `.claude/skills/`, and `.claude/rules/` surface
- edit the exact trigger word list
- show recent reflector runs, trigger source, reflector prompt/output, and AGENTS/CLAUDE/skill diffs
- show queue, prompt-link, hook, scanner, monitor, notification, and last-run status

## Install

```bash
./scripts/install-hooks.sh --reflect-mode immediate
```

This links:

```text
~/.claude/CLAUDE.md -> ~/.introspect/AGENTS.md
~/.codex/AGENTS.md -> ~/.introspect/AGENTS.md
```

It also installs Claude/Codex `UserPromptSubmit` hooks that run `hooks/trigger-reflect.sh`, a Codex transcript scanner LaunchAgent at `~/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist`, and a health monitor LaunchAgent at `~/Library/LaunchAgents/ai.companion.introspect.health.plist`. The scanner is event-driven, not polled: launchd `WatchPaths` wakes it only when Codex writes (a new prompt appends to `~/.codex/history.jsonl`, or a new session adds a rollout file under `~/.codex/sessions`), because Desktop hooks can be skipped until changed hooks are trusted or a running app session reloads config. The health monitor runs once at login (no polling timer) and repairs prompt links, hook config, and scanner launch state when they drift; the app also self-repairs whenever you open it.

Reflection modes:

- `immediate`: enqueue the event and kick one locked worker after trigger. The worker debounces bursts and applies global/session cooldowns.
- `nightly`: enqueue only; install a LaunchAgent at the configured hour/minute.
- `off`: remove hooks while keeping prompt links available.

The reflector runner defaults to `default`: use the installed agent with the most recent local usage history, based on recent Claude and Codex transcript user-message counts. If both are tied, the most recent user message wins; if still tied, Codex wins when installed. No model is pinned unless configured in the app or passed with `--claude-model`, `--claude-fallback-model`, or `--codex-model`; blank, `default`, and `auto` use the CLI default. Use `--runner claude` or `--runner codex` to force one.

## Verify

```bash
readlink ~/.claude/CLAUDE.md
readlink ~/.codex/AGENTS.md
rg "trigger-reflect.sh" ~/.claude/settings.json ~/.codex/hooks.json
INTROSPECT_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
./scripts/test-trigger-words.py
./scripts/introspect-status.sh
```

## How It Works

1. Claude Code or Codex submits a user prompt.
2. `hooks/trigger-reflect.sh` logs prompt metadata to `feedback/events.jsonl`.
3. The hook uses the exact word list from `~/.introspect/trigger-words.txt` when present, otherwise the built-in default list.
4. If the prompt contains an explicit active trigger word, the hook appends it to `feedback/trigger-queue.jsonl`.
5. In immediate mode, the hook kicks `hooks/trigger-worker.py --kick`. In nightly mode, the LaunchAgent runs `hooks/trigger-worker.py --nightly`.
6. Separately, `hooks/codex-transcript-scan.py` scans recent Codex Desktop transcript JSONL files, skips Codex control/context records, dedupes by transcript line, and queues any missed trigger prompts into the same queue.
7. `scripts/introspect-healthcheck.sh` runs from launchd once at login (no polling timer), writes `feedback/health-status.latest`, and repairs local install drift through `scripts/install-hooks.sh`.
8. The worker holds a lock, batches nearby events, applies cooldowns, writes the exact reflector prompt to `feedback/reflector-prompts/`, snapshots relevant agent surfaces before/after, and runs at most one reflector process.
9. The reflector inspects the original thread and stats, then chooses one target: `no_change`, `core_prompt`, `project_prompt`, `home_memory`, `skill_new`, `skill_update`, `project_skill_new`, `project_skill_update`, or `skill_prune`.
10. The app's Runs screen reads `feedback/reflector-batches.jsonl`, `feedback/reflector.log`, and `feedback/surface-diffs/`; it shows matched trigger words, whether the event came from the live hook or Codex scanner backstop, the reflector prompt/output, and the AGENTS/CLAUDE/skill diff. Original Claude/Codex JSONL history stays available as an external open/reveal path instead of an inline chat viewer.

When a real reflector process starts, the worker posts the banner through the signed `Introspect.app`, but only when macOS has authorized that bundle for notifications; otherwise it skips and logs why. The banner body includes the matched trigger words for that run. Use the app's Notifications section to request macOS permission, send a test banner, open System Settings when macOS blocks the app, or disable these popups; the setting is stored in `~/.introspect/settings.json`. `INTROSPECT_NOTIFY=0` still disables popups for a hook or LaunchAgent environment.

## Agent File Scopes

Introspect treats agent memory as a routing problem, not one giant prompt.

- Global invariants belong in `~/.introspect/AGENTS.md`; the installer links `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md` to that same file.
- Project-wide Codex guidance belongs in the repo's `AGENTS.md`; nested `AGENTS.md` files append narrower instructions, with closer files winning on conflicts.
- `AGENTS.override.md` is different: it replaces the regular `AGENTS.md` at that directory level, so use it only when a subtree should override that layer instead of appending to it.
- Claude reads `CLAUDE.md` / `.claude/CLAUDE.md`, not `AGENTS.md` directly, so project `CLAUDE.md` should be a symlink to `AGENTS.md` when no Claude-only additions exist; use a real `CLAUDE.md` with `@AGENTS.md` only for Claude-specific project guidance.
- Private project notes belong in `CLAUDE.local.md` and should stay gitignored.
- Project skills belong beside the codebase: `.agents/skills/<skill>/SKILL.md` for Codex-style project skills and `.claude/skills/<skill>/SKILL.md` for Claude project skills.

References used for this hierarchy: [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md), [AGENTS.md](https://agents.md/), [Claude memory](https://code.claude.com/docs/en/memory), and [Claude skills](https://code.claude.com/docs/en/skills).

## Learning Layers

Self-evolution should not mean "append everything to the system prompt."

- System prompt: durable behavior that should shape nearly every task.
- Project prompt: repo-specific facts, decisions, and local working rules.
- Home memory: durable user preferences, vocabulary, and local machine facts under `~/.introspect/memory`.
- Skills: repeatable procedures, tool workflows, references, scripts, and assets loaded on demand.
- Training/adapters: later behavior work only after enough examples and eval gates exist.

Hermes was reviewed as the main reference for this split. The conclusion is in `docs/hermes-self-evolution-review.md`: use its layered memory/skills/curator shape, but do not copy its eager default skill-writing bias or promote any learned behavior without evals and approval/staging.

## Files

- `Package.swift` and `Sources/IntrospectApp/`: native macOS menu bar/settings app.
- `~/.introspect/AGENTS.md`: live user-wide prompt loaded by Claude and Codex through symlinks.
- `AGENTS.md`: project guidance for developing Introspect itself.
- `skills/index.json`: skill routing index.
- `skills/*/SKILL.md`: scoped skill files.
- `skills/agent-md-creator/SKILL.md`: edits the always-loaded AGENTS.md / CLAUDE.md prompt.
- `skills/skill-creator/SKILL.md`: creates, updates, prunes, and validates scoped skills.
- `hooks/trigger-reflect.sh`: prompt hook entrypoint.
- `hooks/codex-transcript-scan.py`: Codex Desktop transcript scanner backstop.
- `hooks/trigger-worker.py`: locked background batch worker.
- `hooks/trigger-stats.sh`: feedback scoreboard by prompt commit.
- `docs/trigger-words.md`: human-readable list of active and ignored trigger words.
- `docs/hermes-self-evolution-review.md`: source-backed review of Hermes memory, skill, curator, and training loops.
- `docs/skill-manager-reference-review.md`: source-backed review of public skill-manager apps and self-improvement tools.
- `scripts/install-hooks.sh`: installs/uninstalls prompt links and hooks.
- `scripts/introspect-healthcheck.sh`: launchd health monitor that rechecks and repairs local setup.
- `scripts/build-introspect-app.sh`: builds `.build/Introspect.app`.
- `scripts/validate-skills.py`: validates the skill index and skill files.
- `scripts/test-trigger-words.py`: regression test for the foreground trigger detector.
- `scripts/introspect-status.sh`: health check for links, hooks, skills, queue, and recent reflector runs.
- `feedback/`: ignored local queue, stats, and reflector logs.
