# Introspect

Introspect is a CLI/TUI for improving local coding-agent instructions from real conversations.

It watches Claude, Codex, and OpenCode sessions for moments where the agent got stuck, ignored instructions, overclaimed, patched the wrong layer, or needed repeated correction. When that happens, Introspect can run a locked background reflection pass that updates the right instruction surface: global `AGENTS.md`, project `AGENTS.md`, project skills, user-wide skills, or local memory.

Introspect is local-first. Prompts, transcript-derived events, model scores, queued runs, diffs, proposals, and history live on your machine under `~/.introspect`.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/companion-inc/introspect/main/install.sh | bash
```

Then run it:

```bash
introspect
```

On a fresh machine the first run is a guided setup. It shows what Introspect
does, scans your local Claude/Codex history and reports how many past
conversations it found, then (with your confirmation) links your agent
prompts, installs the hooks and transcript watcher, and analyzes recent
history to calibrate the wake detector. After setup, `introspect` opens the
dashboard.

Prefer a non-interactive install (CI, scripts, dotfiles)?

```bash
introspect install            # scriptable, no prompts
introspect onboard --yes      # the guided flow, auto-confirmed
```

Check health:

```bash
introspect status
introspect doctor
```

## CLI

```bash
introspect                    # guided setup on first run, dashboard after
introspect onboard            # re-run the guided setup walkthrough
introspect dashboard --watch  # live dashboard refresh
introspect install            # prompt links, hooks, scanner, monitor, backfill
introspect status             # setup and runtime status
introspect doctor             # status plus local tool checks
introspect runs               # recent reflector runs
introspect diff               # latest AGENTS/CLAUDE/skill diff
introspect config             # print runtime settings
introspect run                # run Introspect on recent transcript changes
introspect uninstall          # remove hooks, scanner, monitor, prompt links
```

Examples:

```bash
introspect install --reflect-mode immediate --runner codex
introspect config --sensitivity sensitive --runner codex
introspect run --host codex --event manual --force
introspect runs -n 20
introspect diff --summary
```

No model is pinned by default. Blank, `default`, and `auto` use the selected CLI's own current default model.

## What Happens On Install

Introspect creates one private local home:

```text
~/.introspect
```

It wires each agent to that home:

```text
~/.claude/CLAUDE.md -> ~/.introspect/AGENTS.md
~/.codex/AGENTS.md -> ~/.introspect/AGENTS.md
~/.config/opencode/AGENTS.md -> ~/.introspect/AGENTS.md
```

It also installs:

- foreground hooks for Claude and Codex prompts
- an event-driven transcript scanner for missed Desktop sessions and assistant-output failures
- a login health check that repairs drift in links, hooks, scanner state, and skill links
- a bounded one-time backfill over recent local Claude/Codex transcripts
- best-effort macOS notifications through `osascript` when a reflector run starts

The backfill scores recent local history into `~/.introspect/feedback/events.jsonl`. It does not queue old history into the reflector, so install does not rewrite your prompts from past conversations. Repeated installs skip backfill unless you explicitly force it.

## Dashboard

Running `introspect` shows:

- install mode, runner, and wake sensitivity
- logged, woke, review-only, backfilled, and assistant-output event counts
- queue and lock state
- last scanner and backfill timestamps
- latest reflector invocation status
- next commands for install, status, runs, diff, and config

`introspect dashboard --watch` refreshes the same view in place.

## How It Works

1. A Claude, Codex, or OpenCode prompt is submitted.
2. The hook records prompt metadata into `~/.introspect/feedback`.
3. A local classifier scores whether this looks like negative feedback or an agent-boundary failure.
4. Low scores are logged for audit only.
5. High-confidence events are appended to `trigger-queue.jsonl`.
6. Immediate mode kicks one locked worker; nightly mode waits for the scheduled reflector.
7. The worker batches nearby events, applies cooldowns, snapshots relevant agent surfaces, and runs one reflector process.
8. The reflector inspects the original thread and chooses one target: no change, global prompt, project prompt, home memory, user skill, project skill, or skill pruning.
9. The worker records the prompt, output, status, notification result, and exact surface diff.
10. The CLI reads those local artifacts through `introspect runs` and `introspect diff`.

The classifier uses word and character features because the signal is not only exact words; it also needs to catch misspellings, repeated corrections, punctuation-heavy frustration, and phrases it has not seen verbatim. That is scoring, not a hardcoded slur list.

## Agent File Scopes

Introspect keeps global, project, and skill instructions separate.

- Global invariants live in `~/.introspect/AGENTS.md`.
- Codex project guidance lives in the repo's `AGENTS.md`.
- Nested `AGENTS.md` files apply narrower guidance closer to the working directory.
- `AGENTS.override.md` replaces the broader Codex file for a subtree.
- Claude reads `CLAUDE.md`, so project `CLAUDE.md` should usually be a symlink to `AGENTS.md`.
- Private Claude project notes belong in `CLAUDE.local.md` and should stay gitignored.
- User-wide skills live under `~/.introspect/skills/<skill>/SKILL.md`.
- Codex/OpenCode project skills live under `.agents/skills/<skill>/SKILL.md`.
- Claude project skills live under `.claude/skills/<skill>/SKILL.md`.

Introspect exports each user-wide skill into one native global namespace to avoid duplicate OpenCode-visible skill names:

- default / `compatibility: codex` -> `~/.agents/skills`
- `compatibility: claude` -> `~/.claude/skills`
- `compatibility: opencode` -> `~/.config/opencode/skills`

References:

- [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Codex Skills](https://developers.openai.com/codex/skills)
- [AGENTS.md](https://agents.md/)
- [Claude memory](https://code.claude.com/docs/en/memory)
- [Claude skills](https://code.claude.com/docs/en/skills)
- [OpenCode rules](https://opencode.ai/docs/rules/)
- [OpenCode skills](https://opencode.ai/docs/skills/)

## Build From Source

```bash
git clone https://github.com/companion-inc/introspect.git
cd introspect
./bin/introspect
./bin/introspect install
```

Requirements:

- macOS
- Python 3
- Git
- Claude and/or Codex CLI installed for reflection runs

## Verify

```bash
./scripts/test-install-paths.sh
/usr/bin/python3 scripts/test-trigger-words.py
/usr/bin/python3 scripts/test-reflector-prompt-contract.py
INTROSPECT_SKILLS_DIR="$PWD/skills" /usr/bin/python3 scripts/validate-skills.py
./scripts/test-release-e2e.sh
./bin/introspect status
```

## Repository Layout

- `bin/introspect`: CLI and terminal dashboard.
- `install.sh`: curl-install entrypoint.
- `hooks/trigger-reflect.sh`: prompt hook entrypoint.
- `hooks/codex-transcript-scan.py`: transcript scanner and install backfill.
- `hooks/trigger-worker.py`: locked background batch worker.
- `hooks/intent_classifier.py`: local wake classifier runtime.
- `models/`: bundled classifier models.
- `scripts/install-hooks.sh`: installer for prompt links, hooks, scanner, monitor, and backfill.
- `scripts/introspect-status.sh`: end-to-end local status check.
- `scripts/test-release-e2e.sh`: CLI release smoke test.
- `skills/`: built-in Introspect skills and skill index.
- `templates/default-AGENTS.md`: default global prompt template seeded into `~/.introspect`.
- `docs/`: design notes, source reviews, and runtime contracts.

## Privacy

Introspect is local-first:

- it reads local Claude/Codex/OpenCode prompt and transcript files
- it writes local feedback and run artifacts under `~/.introspect`
- it uses your installed Claude or Codex CLI only when a reflector run is triggered
- it does not upload your transcript archive to a Companion server
- it does not install a default banned-word list

## License

MIT
