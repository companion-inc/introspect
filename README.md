# Introspect

Introspect is a local terminal CLI and background hook runtime for improving coding-agent instructions from real conversations.

It ships no graphical bundle or menu-bar process. macOS is the supported runtime today because Introspect uses local Claude/Codex/OpenCode files, shell hooks, LaunchAgents, and best-effort `osascript` notifications.

Introspect watches local Claude, Codex, and OpenCode sessions for moments where an agent got stuck, ignored instructions, overclaimed, patched the wrong layer, or needed repeated correction. When a real failure is detected, a locked reflector run inspects the source transcript and updates the right durable surface: global `AGENTS.md`, project `AGENTS.md`, project skills, user-wide skills, or local memory. It can also decide that no change is justified.

All runtime state stays local under `~/.introspect`: prompt links, settings, transcript-derived events, classifier scores, queued runs, reflector prompts, surface diffs, proposals, run history, local memory, and user-wide skills.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/companion-inc/introspect/main/install.sh | bash
```

Then run:

```bash
introspect
```

On a fresh machine, `introspect` starts the guided setup. It shows what will be installed, counts local Claude/Codex history, links native agent prompt files, installs prompt hooks and the transcript scanner, starts the health monitor, and runs a bounded history backfill for classifier calibration. After setup, `introspect` opens the terminal dashboard.

Scriptable install:

```bash
introspect install
introspect onboard --yes
```

Health checks:

```bash
introspect status
introspect doctor
```

## Commands

```bash
introspect                    # setup on first run, dashboard after setup
introspect onboard            # guided setup walkthrough
introspect install            # prompt links, hooks, scanner, monitor, backfill
introspect status             # setup and runtime status
introspect doctor             # status plus local tool checks
introspect dashboard --watch  # live terminal dashboard
introspect runs               # recent reflector runs
introspect diff               # latest agent-surface diff
introspect config             # print or update runtime settings
introspect run                # run Introspect on recent transcript changes
introspect notify             # send a best-effort macOS notification
introspect uninstall          # remove hooks, scanner, monitor, prompt links
```

Common configuration:

```bash
introspect install --reflect-mode immediate --apply-mode auto --runner codex
introspect config --sensitivity sensitive --apply-mode auto --runner codex
introspect run --host codex --event manual --apply auto --force
introspect runs -n 20
introspect diff --summary
```

No model is pinned by default. Blank, `default`, and `auto` mean "use the selected CLI's current default model."

## Runtime Modes

Reflect mode controls when the worker runs:

- `immediate`: foreground hooks enqueue the event and kick one locked worker.
- `nightly`: foreground hooks enqueue events and the scheduled LaunchAgent runs the worker.
- `off`: prompt links remain, but reflection hooks and scanner work are disabled.

Apply mode controls where changes land:

- `proposal`: project prompt and project skill changes are written under `~/.introspect/proposals`.
- `auto`: the reflector can edit and commit the target repo's project `AGENTS.md` or project skills directly.
- `never`: manual runs index transcript changes without invoking the reflector.

Runner controls which installed agent executes the reflector:

- `default`: pick the installed agent with the most recent local usage.
- `codex`: force Codex CLI.
- `claude`: force Claude CLI.

## What Install Wires

Introspect creates one private home:

```text
~/.introspect
```

It links each host's native prompt file to that home:

```text
~/.claude/CLAUDE.md -> ~/.introspect/AGENTS.md
~/.codex/AGENTS.md -> ~/.introspect/AGENTS.md
~/.config/opencode/AGENTS.md -> ~/.introspect/AGENTS.md
```

It installs:

- Claude and Codex foreground prompt hooks
- a Codex/Claude transcript scanner for missed direct user messages, woken by file events plus a 60-second backstop
- a login health monitor that repairs drift in links, hook config, scanner state, and skill exports
- an optional nightly reflector LaunchAgent when `--reflect-mode nightly` is selected
- a bounded one-time local history backfill
- best-effort local notifications through `osascript`

The backfill scores recent local history into `~/.introspect/feedback/events.jsonl`. It does not queue old history into the reflector, so install does not rewrite prompts from old conversations. Repeated installs skip backfill unless `--force-backfill` is used.

## Dashboard

The terminal dashboard shows:

- runtime commit and prompt commit
- install mode, runner, apply mode, and wake sensitivity
- logged, triggered, review-only, backfilled, direct-user, and raw event counts
- queue and lock state
- latest scanner and backfill timestamps
- latest reflector invocation status
- recent reflector log tail
- next commands for install, status, runs, diff, and config

`introspect dashboard --watch` refreshes the same view in place.

## How It Works

1. A Claude, Codex, or OpenCode prompt is submitted.
2. A hook or transcript scanner records direct user prompt metadata under `~/.introspect/feedback`.
3. The local classifier scores whether the direct user message looks like negative feedback or an agent-boundary failure.
4. Low scores are logged for audit only.
5. Review-tier near-repeat corrections across chats in the same project can wake through local repetition pressure.
6. High-confidence or repeated-pressure events are appended to `trigger-queue.jsonl`.
7. The locked worker debounces nearby events, batches them, applies cooldowns, snapshots relevant agent surfaces, and runs one reflector process in the configured apply mode.
8. The reflector reads the source transcript and chooses one target: no change, global prompt, project prompt, home memory, user skill, project skill, or skill pruning.
9. The worker records the reflector prompt, output, status, notification result, and exact surface diff.
10. The CLI reads those local artifacts through `introspect status`, `introspect runs`, and `introspect diff`.

The classifier uses word and character features because the signal is not only exact words; it also catches misspellings, punctuation-heavy frustration, and phrases it has not seen verbatim. Repetition pressure is separate: it counts similar review-tier complaints across distinct recent user turns in the same project, stores hashed local features under the feedback directory, and ignores assistant messages, Codex file/context wrappers, control phrases, pasted context, and hook/scanner duplicate observations.

## Instruction Surfaces

Introspect keeps global, project, and skill instructions separate.

- Global invariants live in `~/.introspect/AGENTS.md`.
- Codex project guidance lives in the repo's `AGENTS.md`.
- Nested `AGENTS.md` files apply narrower guidance closer to the working directory.
- `AGENTS.override.md` replaces the broader Codex file for a subtree.
- Claude reads `CLAUDE.md`; project `CLAUDE.md` should usually be a symlink to `AGENTS.md`.
- Private Claude project notes belong in `CLAUDE.local.md` and should stay gitignored.
- User-wide skills live under `~/.introspect/skills/<skill>/SKILL.md`.
- Codex/OpenCode project skills live under `.agents/skills/<skill>/SKILL.md`.
- Claude project skills live under `.claude/skills/<skill>/SKILL.md`.

Introspect exports each user-wide skill into one native global namespace to avoid duplicate OpenCode-visible skill names:

- default or `compatibility: codex` -> `~/.agents/skills`
- `compatibility: claude` -> `~/.claude/skills`
- `compatibility: opencode` -> `~/.config/opencode/skills`

## Build From Source

```bash
git clone https://github.com/companion-inc/introspect.git
cd introspect
./bin/introspect
./bin/introspect install
```

Requirements:

- macOS
- `/usr/bin/python3`
- Git
- Claude CLI or Codex CLI for reflector runs

## Verify

```bash
./scripts/test-install-paths.sh
/usr/bin/python3 scripts/test-trigger-words.py
/usr/bin/python3 scripts/test-reflector-prompt-contract.py
/usr/bin/python3 scripts/test-introspect-run.py
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
- `hooks/repetition_pressure.py`: local review-tier repetition pressure runtime.
- `models/`: bundled classifier models.
- `scripts/install-hooks.sh`: installer for prompt links, hooks, scanner, monitor, and backfill.
- `scripts/introspect-status.sh`: end-to-end local status check.
- `scripts/test-release-e2e.sh`: CLI release smoke test.
- `skills/`: built-in Introspect skills and skill index.
- `templates/default-AGENTS.md`: default global prompt template seeded into `~/.introspect`.
- `docs/`: design notes, source reviews, and runtime contracts.

## Privacy

Introspect is local-first:

- it reads local Claude, Codex, and OpenCode prompt and transcript files
- it writes local feedback and run artifacts under `~/.introspect`
- it uses the installed Claude or Codex CLI only when a reflector run is triggered
- it does not upload the local transcript archive to a Companion server
- it does not install a default banned-word list

## References

- [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Codex Skills](https://developers.openai.com/codex/skills)
- [AGENTS.md](https://agents.md/)
- [Claude memory](https://code.claude.com/docs/en/memory)
- [Claude skills](https://code.claude.com/docs/en/skills)
- [OpenCode rules](https://opencode.ai/docs/rules/)
- [OpenCode skills](https://opencode.ai/docs/skills/)

## License

MIT
