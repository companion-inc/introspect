# Introspect

Introspect is a local macOS tool that helps coding agents improve from real conversations.

It watches your Claude, Codex, and OpenCode sessions for moments where the agent got stuck, ignored instructions, overclaimed, patched the wrong layer, or needed repeated correction. When that happens, Introspect can run a locked background reflection pass that updates the right agent instruction surface: global `AGENTS.md`, project `AGENTS.md`, project skills, or user-wide skills.

It is not a hosted service. Your prompts, transcripts, feedback logs, model scores, proposed edits, and Introspect history live on your Mac under `~/.introspect`.

## Download

Download the latest macOS build:

[Download Introspect.dmg](https://github.com/companion-inc/introspect/releases/latest/download/Introspect.dmg)

Open the DMG, drag `Introspect.app` to Applications, then open Introspect.

The app is the friendly installer and status UI. The same runtime also exposes a CLI:

```bash
/Applications/Introspect.app/Contents/MacOS/Introspect --install
/Applications/Introspect.app/Contents/MacOS/Introspect --status
/Applications/Introspect.app/Contents/MacOS/Introspect --uninstall
```

## What Happens After Install

On first install, Introspect sets up one private local home:

```text
~/.introspect
```

That home contains the shared prompt, settings, skills, local memory, feedback history, reflector runs, and proposals. Durable files are Git-tracked inside `~/.introspect`; runtime logs and generated feedback artifacts are ignored.

Then Introspect wires each agent to that home:

```text
~/.claude/CLAUDE.md -> ~/.introspect/AGENTS.md
~/.codex/AGENTS.md -> ~/.introspect/AGENTS.md
~/.config/opencode/AGENTS.md -> ~/.introspect/AGENTS.md
```

It also installs:

- foreground hooks for Claude and Codex prompts
- an event-driven transcript scanner for missed Desktop sessions and assistant-output failures
- a login health check that repairs drift in links, hooks, scanner state, and skill links
- a bounded one-time backfill over recent local Claude/Codex transcripts so the app starts with useful signal
- optional macOS notifications when a reflector run starts

The backfill scores recent local history into `~/.introspect/feedback/events.jsonl`. It does not queue old history into the reflector, so installing the app does not rewrite your prompts from past conversations. Repeated installs skip backfill unless you explicitly force it.

## What You See

The app opens to a status dashboard, not a blank settings shell.

- **Status** shows whether prompt links, hooks, scanner, health monitor, notifications, queue, and latest run are working.
- **Signals** shows captured events, wake scores, trigger rates, optional review-term matches, run outcomes, and local tone scores.
- **Runs** shows each reflector batch, the source locator, the prompt/output, and the AGENTS/CLAUDE/skill diff it produced.
- **Projects** shows discovered global and project agent files plus project skills.
- **Introspect Home** shows the private `~/.introspect` Git history and selected commit patches.
- **Hooks** controls immediate, nightly, or off mode plus runner selection.
- **Review Terms** lets you add optional words to track without making those words the wake trigger.
- **Notifications** requests macOS permission, sends a test banner, and opens System Settings when macOS blocks delivery.

## CLI

The app binary is also the main CLI entrypoint:

```bash
Introspect --install [install flags]
Introspect --status
Introspect --uninstall
Introspect --request-notification
Introspect --post-notification "Introspect" "Reflector started"
Introspect --notification-status
```

Install flags pass through to the runtime installer:

```bash
Introspect --install \
  --reflect-mode immediate \
  --runner codex \
  --wake-sensitivity sensitive
```

For source checkouts, the scripts are directly runnable:

```bash
./scripts/install-hooks.sh --reflect-mode immediate
./scripts/introspect-status.sh
./scripts/test-release-e2e.sh
```

Reflection modes:

- `immediate`: enqueue a triggered event and kick one locked worker after debounce/cooldown.
- `nightly`: enqueue events and process them at the configured local time.
- `off`: remove hooks/scanner/reflector scheduling while keeping prompt files available.

Runner selection:

- `default` chooses the installed agent with the most recent local usage.
- `claude` forces Claude.
- `codex` forces Codex.

No model is pinned by default. Blank, `default`, and `auto` use the selected CLI's own default model.

## How It Works

1. A Claude, Codex, or OpenCode prompt is submitted.
2. The hook records prompt metadata into the active feedback directory.
3. A local classifier scores whether this looks like negative feedback or an agent-boundary failure.
4. Low scores are logged for audit only.
5. High-confidence events are appended to `trigger-queue.jsonl`.
6. Immediate mode kicks one locked worker; nightly mode waits for the scheduled reflector.
7. The worker batches nearby events, applies cooldowns, snapshots relevant agent surfaces, and runs one reflector process.
8. The reflector inspects the original thread and chooses one target: no change, global prompt, project prompt, home memory, user skill, project skill, or skill pruning.
9. The worker records the prompt, output, status, notification result, and exact surface diff.
10. The app reads those local artifacts and shows what changed.

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

References for this hierarchy:

- [OpenAI Codex AGENTS.md](https://developers.openai.com/codex/guides/agents-md)
- [OpenAI Codex Skills](https://developers.openai.com/codex/skills)
- [AGENTS.md](https://agents.md/)
- [Claude memory](https://code.claude.com/docs/en/memory)
- [Claude skills](https://code.claude.com/docs/en/skills)
- [OpenCode rules](https://opencode.ai/docs/rules/)
- [OpenCode skills](https://opencode.ai/docs/skills/)

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode command line tools
- Swift
- Python 3
- Claude and/or Codex CLI installed for reflection runs

Build:

```bash
./scripts/build-introspect-app.sh
open .build/Introspect.app
```

Create a local DMG:

```bash
./scripts/build-introspect-app.sh
./scripts/build-dmg.sh
```

## Verify

```bash
./scripts/test-install-paths.sh
/usr/bin/python3 scripts/test-trigger-words.py
/usr/bin/python3 scripts/test-reflector-prompt-contract.py
INTROSPECT_SKILLS_DIR="$PWD/skills" /usr/bin/python3 scripts/validate-skills.py
./scripts/test-release-e2e.sh
./scripts/build-introspect-app.sh
codesign --verify --deep --strict --verbose=2 .build/Introspect.app
```

For an installed app:

```bash
/Applications/Introspect.app/Contents/MacOS/Introspect --status
```

## Repository Layout

- `Sources/IntrospectApp/`: native macOS app and CLI entrypoint.
- `hooks/trigger-reflect.sh`: prompt hook entrypoint.
- `hooks/codex-transcript-scan.py`: transcript scanner and install backfill.
- `hooks/trigger-worker.py`: locked background batch worker.
- `hooks/intent_classifier.py`: local wake classifier runtime.
- `models/`: bundled classifier models.
- `scripts/install-hooks.sh`: installer for prompt links, hooks, scanner, monitor, and backfill.
- `scripts/introspect-status.sh`: end-to-end local status check.
- `scripts/build-introspect-app.sh`: app bundle builder.
- `scripts/build-dmg.sh`: DMG builder for local release artifacts.
- `scripts/test-release-e2e.sh`: packaged-app release smoke test.
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

The bundle identifier is `ai.companion.introspect`. That matters for macOS signing, notifications, and Launch Services; it is not the product pitch.

## License

MIT
