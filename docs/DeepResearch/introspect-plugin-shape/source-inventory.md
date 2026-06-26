# Source Inventory

## Local Introspect

- `README.md:3-7`: Introspect is a local terminal CLI and background hook runtime for improving coding-agent instructions from real conversations, with local state under `~/.introspect`.
- `README.md:79-92`: Current install links Claude, Codex, and OpenCode prompt files and installs hooks, scanner, health check, and backfill.
- `README.md:109-120`: Current pipeline is classifier-scored trigger events, queue, worker, reflector, and surface diff tracking.
- `README.md:122-140`: Current instruction surfaces differ by host: global `~/.introspect/AGENTS.md`, repo `AGENTS.md`, Claude `CLAUDE.md`, user skills, project skills, and host export roots.
- `hooks/trigger-reflect.sh:1-14`: Current foreground hook logs every prompt and wakes a reflector only on classifier triggers.
- `hooks/trigger-worker.py:1-7`: Current worker batches trigger events, locks, debounces, and runs one reflector agent.
- `hooks/codex-transcript-scan.py:1-8`: Current scanner is a backstop transcript path that feeds the same queue.
- `scripts/install-hooks.sh:47-64`: Current installer is a cross-host hook/prompt-link installer, not a host-native plugin adapter.
- `scripts/install-hooks.sh:300-328`: `~/.introspect` owns prompt, trigger words, settings, skills, memory, feedback, runs, proposals, and models.

## Codex Official Docs

Source fetched through the OpenAI docs helper on 2026-06-22:

- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:7402-7405`: skills are reusable workflows; plugins are the installable distribution unit for reusable skills and apps.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:7414-7423`: a skill is a directory with `SKILL.md`; Codex activates skills by explicit or implicit invocation.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:7452-7485`: Codex skill locations and plugin distribution guidance.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:10723-10728`: build a plugin when sharing a stable workflow, bundling app integrations/MCP config, or packaging lifecycle hooks.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:10790-10807`: minimal Codex plugin has `.codex-plugin/plugin.json` and can point to `skills`.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:11159-11185`: Codex loads hooks from config layers and plugin-bundled hooks.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:11825-11837`: Codex plugins can contain skills, apps, MCP servers, and marketplace distribution.
- `/var/folders/dh/jp0vmmzn54gc0pbm2zjrjt9r0000gn/T/openai-docs-cache/codex-manual.md:8128-8144`: plugin-provided MCP servers are launched from the plugin and controlled under plugin config.

## Cursor Continual Learning Reference

- `https://raw.githubusercontent.com/cursor/plugins/main/continual-learning/.cursor-plugin/plugin.json`: manifest registers agent, skill, and hook directories.
- `https://raw.githubusercontent.com/cursor/plugins/main/continual-learning/hooks/hooks.json`: one stop hook runs `continual-learning-stop.ts`.
- `https://raw.githubusercontent.com/cursor/plugins/main/continual-learning/hooks/continual-learning-stop.ts`: hook keeps cadence/index state, gates on completed root turns, generation de-dupe, turn count, minutes since last run, and transcript mtime.
- `https://raw.githubusercontent.com/cursor/plugins/main/continual-learning/skills/continual-learning/SKILL.md`: skill is orchestration-only and delegates to updater.
- `https://raw.githubusercontent.com/cursor/plugins/main/continual-learning/agents/agents-memory-updater.md`: updater reads changed transcripts, updates `AGENTS.md` learned preference/fact sections, dedupes, caps sections, and emits no-op text when no high-signal update exists.

## Claude Code Research Lane

Subagent Euclid reported these primary sources:

- `https://code.claude.com/docs/en/overview`: Claude Code extension surfaces.
- `https://code.claude.com/docs/en/memory`: `CLAUDE.md`, `CLAUDE.local.md`, imports, and memory behavior.
- `https://code.claude.com/docs/en/skills`: Claude skills under global and project roots.
- `https://code.claude.com/docs/en/hooks`: Claude Code hook events including `Stop`, `SessionStart`, and tool hooks.
- `https://code.claude.com/docs/en/plugins`: Claude plugin overview.
- `https://code.claude.com/docs/en/plugins-reference`: Claude plugin manifest and bundled surfaces including skills, agents, hooks, MCP, LSP, monitors, and marketplaces.

## OpenCode Research Lane

Subagent Euclid reported these primary sources:

- `https://opencode.ai/docs/rules/`: OpenCode durable instruction sources including `AGENTS.md`.
- `https://opencode.ai/docs/skills/`: OpenCode skill roots include `.opencode`, `.claude`, and `.agents` compatible locations.
- `https://opencode.ai/docs/plugins/`: OpenCode plugins are JS/TS modules or npm packages returning hooks/tools/integrations.
- `https://opencode.ai/docs/config/`: plugin configuration through `opencode.json`.
- `https://opencode.ai/docs/commands/`: command surfaces.
- `/tmp/introspect-opencode-research/packages/plugin/src/index.ts:222`: plugin API source used by the research lane.
