# Introspect

Open-source macOS app and hook engine for improving local Claude/Codex agent instructions from real trigger signals.

Bundle identifier:

```text
ai.companion.introspect
```

The public repo contains the app, hooks, worker, scripts, default prompt/skill templates, and docs. User-specific prompt, skill, review-term, memory, model, feedback, and run state lives under `~/.introspect`; durable prompt, settings, skill, and memory files are Git-tracked there, while runtime feedback, run, proposal, and model artifacts are ignored.

This checkout is the reusable app/engine. The Git-tracked user-wide prompt source is `~/.introspect/AGENTS.md`; the installer links Claude, Codex, and OpenCode native prompt files directly to that source.

## Mac App

Build the app:

```bash
./scripts/build-introspect-app.sh
open .build/Introspect.app
```

The app can:

- apply the system prompt links for Claude, Codex, and OpenCode
- install hooks in `immediate`, `nightly`, or `off` mode
- install the Codex transcript scanner backstop for Desktop sessions whose hooks have not fired
- install a recurring health monitor that verifies links, hooks, scanner state, and repairs drift
- remove hooks without deleting the prompt links
- initialize `~/.introspect` as a local Git repo
- show discovered global/project agent files and project skills
- initialize a project's `AGENTS.md`, symlinked `CLAUDE.md`, `.agents/skills/`, `.claude/skills/`, and `.claude/rules/` surface
- edit optional review terms without installing a default word list
- inspect trigger signal analytics: optional review-term counts, version trigger rates, run outcomes, and local tone scores
- inspect classifier audit metrics, threshold curves, and prompt-variant comparisons
- show recent reflector runs, trigger source, reflector prompt/output, and AGENTS/CLAUDE/skill diffs
- show the exact event locator for a run's source message when the hook or Codex scanner can provide one
- browse the private `~/.introspect` Git history and per-commit patches from the app
- show queue, prompt-link, hook, scanner, monitor, notification, and last-run status

## Install

```bash
./scripts/install-hooks.sh --reflect-mode immediate
```

This links:

```text
~/.claude/CLAUDE.md -> ~/.introspect/AGENTS.md
~/.codex/AGENTS.md -> ~/.introspect/AGENTS.md
~/.config/opencode/AGENTS.md -> ~/.introspect/AGENTS.md
```

It also syncs `~/.introspect/skills/<skill>/SKILL.md` folders into agent-native global skill directories with symlinks. Each skill is exported to exactly one native namespace to avoid duplicate OpenCode skill names: the default is `~/.agents/skills` for Codex/OpenCode, `compatibility: claude` exports to `~/.claude/skills`, and `compatibility: opencode` exports to `~/.config/opencode/skills`.

It installs Claude/Codex `UserPromptSubmit` hooks that run `hooks/trigger-reflect.sh`, a Codex transcript scanner LaunchAgent at `~/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist`, and a health monitor LaunchAgent at `~/Library/LaunchAgents/ai.companion.introspect.health.plist`. The scanner is event-driven, not polled: launchd `WatchPaths` wakes it only when Codex writes (a new prompt appends to `~/.codex/history.jsonl`, or a new session adds a rollout file under `~/.codex/sessions`), because Desktop hooks can be skipped until changed hooks are trusted or a running app session reloads config. The health monitor runs once at login (no polling timer) and repairs prompt links, skill links, hook config, and scanner launch state when they drift; the app also self-repairs whenever you open it.

Reflection modes:

- `immediate`: enqueue the event and kick one locked worker after trigger. The worker debounces bursts and applies global/session cooldowns.
- `nightly`: enqueue only; install a LaunchAgent at the configured hour/minute.
- `off`: remove hooks while keeping prompt links available.

The reflector runner defaults to `default`: use the installed agent with the most recent local usage history, based on recent Claude and Codex transcript user-message counts. If both are tied, the most recent user message wins; if still tied, Codex wins when installed. No model is pinned unless configured in the app or passed with `--claude-model`, `--claude-fallback-model`, or `--codex-model`; blank, `default`, and `auto` use the CLI default. `--claude-fallback-model` is Claude CLI's fallback-model flag, not a separate runner. Use `--runner claude` or `--runner codex` to force one.

## Verify

```bash
readlink ~/.claude/CLAUDE.md
readlink ~/.codex/AGENTS.md
readlink ~/.config/opencode/AGENTS.md
rg "trigger-reflect.sh" ~/.claude/settings.json ~/.codex/hooks.json
INTROSPECT_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
./scripts/sync-user-skills.sh
./scripts/test-user-skill-sync.sh
./scripts/test-surface-scopes.py
./scripts/test-reflector-prompt-contract.py
./scripts/test-trigger-words.py
./scripts/build-introspect-app.sh
./scripts/test-release-e2e.sh
./scripts/introspect-status.sh
```

## How It Works

1. Claude Code or Codex submits a user prompt.
2. `hooks/trigger-reflect.sh` logs prompt metadata to the active feedback directory. Installed apps use `~/.introspect/feedback`; checkout/dev installs use `feedback/` in the repo.
3. The hook scores wake intent with the exportable local classifier at `~/.introspect/models/wake-logreg-v2-round4.json` unless `INTROSPECT_WAKE_CLASSIFIER=0`. The production wake threshold is `0.675`; lower scores down to the review threshold are logged for audit but do not wake the reflector.
4. `~/.introspect/trigger-words.txt` is optional review metadata only. Introspect does not install defaults; word fallback is disabled unless `INTROSPECT_TRIGGER_WORD_FALLBACK=1`.
5. If the classifier says the prompt is a foreground wake, the hook appends it to `trigger-queue.jsonl` in the active feedback directory with the event id, message locator, prompt hash, classifier score, optional review-term matches, snippet, and transcript identity fields available from the hook input.
6. In immediate mode, the hook kicks `hooks/trigger-worker.py --kick`. In nightly mode, the LaunchAgent runs `hooks/trigger-worker.py --nightly`.
7. Separately, `hooks/codex-transcript-scan.py` scans recent Codex Desktop transcript JSONL files, skips Codex control/context records, dedupes by transcript line, and queues any missed classifier-triggered prompts into the same queue with a stable `message_locator` of `transcript_path:line`.
8. `scripts/introspect-healthcheck.sh` runs from launchd once at login (no polling timer), writes `health-status.latest` in the active feedback directory, and repairs local install drift through `scripts/install-hooks.sh`.
9. The worker holds a lock, batches nearby events, applies cooldowns, writes the exact reflector prompt to `reflector-prompts/` in the active feedback directory, snapshots relevant agent surfaces before/after, and runs at most one reflector process.
10. The reflector inspects the original thread and stats, then chooses one target: `no_change`, `core_prompt`, `project_prompt`, `home_memory`, `skill_new`, `skill_update`, `project_skill_new`, `project_skill_update`, or `skill_prune`.
11. The worker passes the event id, source, message locator, transcript line, classifier result, optional review-term matches, and snippet to the reflector so the AI can inspect the exact message before classifying the run.
12. The app's Signals screen reads `events.jsonl`, `reflector-batches.jsonl`, `surface-diffs/`, and `intent-classifier/` from the active feedback directory; it shows optional review-term counts, trigger rates by prompt version, run/change counts by term, local sentiment scores, and classifier audit metrics.
13. The app's Runs screen reads `reflector-batches.jsonl`, `reflector.log`, and `surface-diffs/` from the active feedback directory; it shows source, event locator, classifier/review metadata, reflector prompt/output, and the AGENTS/CLAUDE/skill diff. Original Claude/Codex JSONL history stays available as an external open/reveal path instead of an inline chat viewer.
14. The app's Introspect Home screen reads the private `~/.introspect` Git repo and shows the working-tree status, commit list, and selected commit patch.

When a real reflector process starts, the worker posts the banner through the signed `Introspect.app`, but only when macOS has authorized that bundle for notifications; otherwise it skips and logs why. The banner body includes optional review-term matches when present. Use the app's Notifications section to request macOS permission, send a test banner, open System Settings when macOS blocks the app, or disable these popups; the setting is stored in `~/.introspect/settings.json`. `INTROSPECT_NOTIFY=0` still disables popups for a hook or LaunchAgent environment.

## Agent File Scopes

Introspect treats agent memory as a routing problem, not one giant prompt.

- Global invariants are authored in `~/.introspect/AGENTS.md` and linked directly into `~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, and `~/.config/opencode/AGENTS.md`.
- Project-wide Codex guidance belongs in the repo's `AGENTS.md`; nested `AGENTS.md` files append narrower instructions, with closer files winning on conflicts.
- `AGENTS.override.md` is different: it replaces the regular `AGENTS.md` at that directory level, so use it only when a subtree should override that layer instead of appending to it.
- Claude reads `CLAUDE.md` / `.claude/CLAUDE.md`, not `AGENTS.md` directly, so project `CLAUDE.md` should be a symlink to `AGENTS.md` when no Claude-only additions exist; use a real `CLAUDE.md` with `@AGENTS.md` only for Claude-specific project guidance.
- OpenCode reads `AGENTS.md`; project `AGENTS.md` and `.agents/skills/<skill>/SKILL.md` cover OpenCode without duplicating project files.
- Private project notes belong in `CLAUDE.local.md` and should stay gitignored.
- User-wide skills are authored once under `~/.introspect/skills/<skill>/SKILL.md`; Introspect links each one into exactly one native global skill folder. Default / `compatibility: codex` goes to `~/.agents/skills`, `compatibility: claude` goes to `~/.claude/skills`, and `compatibility: opencode` goes to `~/.config/opencode/skills`.
- OpenCode loads global skills from `~/.config/opencode/skills`, `~/.claude/skills`, and `~/.agents/skills`, so the same skill name must not be exported to more than one of those roots.
- Project skills belong beside the codebase: `.agents/skills/<skill>/SKILL.md` for Codex/OpenCode project skills and `.claude/skills/<skill>/SKILL.md` for Claude project skills.
- Introspect scans those surfaces from `~/.introspect`, `~/.codex`, `~/.claude`, `~/.agents`, `~/.config/opencode`, and project roots; nested project files are shown relative to the nearest project marker.

References used for this hierarchy: [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md), [OpenAI Codex Skills](https://developers.openai.com/codex/skills), [AGENTS.md](https://agents.md/), [Claude memory](https://code.claude.com/docs/en/memory), [Claude skills](https://code.claude.com/docs/en/skills), [OpenCode rules](https://opencode.ai/docs/rules/), and [OpenCode skills](https://opencode.ai/docs/skills/).

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
- `~/.introspect/AGENTS.md`: Git-tracked user-wide prompt source linked into each agent's native prompt file.
- `AGENTS.md`: project guidance for developing Introspect itself.
- `skills/index.json`: skill routing index.
- `skills/*/SKILL.md`: scoped skill files.
- `skills/agent-md-creator/SKILL.md`: edits the always-loaded AGENTS.md / CLAUDE.md prompt.
- `skills/skill-creator/SKILL.md`: creates, updates, prunes, and validates scoped skills.
- `hooks/trigger-reflect.sh`: prompt hook entrypoint.
- `hooks/codex-transcript-scan.py`: Codex Desktop transcript scanner backstop.
- `hooks/trigger-worker.py`: locked background batch worker.
- `hooks/trigger-stats.sh`: feedback scoreboard by prompt commit.
- `docs/review-terms.md`: classifier-first wake behavior and optional review-term metadata.
- `docs/hermes-self-evolution-review.md`: source-backed review of Hermes memory, skill, curator, and training loops.
- `docs/skill-manager-reference-review.md`: source-backed review of public skill-manager apps and self-improvement tools.
- `scripts/install-hooks.sh`: installs/uninstalls prompt links and hooks.
- `scripts/introspect-healthcheck.sh`: launchd health monitor that rechecks and repairs local setup.
- `scripts/sync-user-skills.sh`: links each `~/.introspect/skills` entry into the one Claude/Codex/OpenCode global skill folder selected by its compatibility metadata.
- `scripts/build-introspect-app.sh`: builds `.build/Introspect.app`.
- `scripts/validate-skills.py`: validates the skill index and skill files.
- `scripts/test-surface-scopes.py`: regression test for global/project prompt and skill surface classification.
- `scripts/test-reflector-prompt-contract.py`: regression test for reflector global/project/local layer selection.
- `scripts/test-release-e2e.sh`: packaged-app release smoke test with a fake HOME, install/status/dry-run/uninstall trace, and bundle privacy checks.
- `scripts/test-user-skill-sync.sh`: regression test for compatibility-aware user skill export.
- `scripts/test-install-paths.sh`: regression test for the `~/.introspect` install contract.
- `scripts/test-trigger-words.py`: regression test for the foreground trigger detector.
- `scripts/introspect-status.sh`: health check for links, hooks, skills, queue, and recent reflector runs.
- `feedback/`: ignored local queue, stats, and reflector logs for checkout/dev installs; packaged app installs write these under `~/.introspect/feedback`.
