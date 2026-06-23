# Why Chains

## Why not one universal plugin?

Observation:

- Codex plugins package skills, hooks, apps, MCP servers, and marketplace metadata. Sources: Codex manual `codex-manual.md:10723-10728`, `codex-manual.md:11825-11837`.
- Claude Code has a first-class plugin bundle with Claude-specific surfaces such as agents, hooks, skills, MCP, LSP, monitors, and marketplaces. Source: Claude research lane in `source-inventory.md`.
- OpenCode plugins are executable JS/TS modules or npm packages, while rules, skills, commands, tools, and agents remain separate native filesystem/config surfaces. Source: OpenCode research lane in `source-inventory.md`.
- Cursor's continual-learning plugin is a `.cursor-plugin` package with Cursor-specific agents, skills, and hooks. Source: Cursor raw files in `source-inventory.md`.

Mechanism:

Each host has a different install authority and discovery path. A universal plugin would either ignore host features or add a private abstraction that users must debug in addition to the native host standard.

Decision:

Use one shared core and separate adapters. The shared core owns durable state and learning logic; adapters own host packaging and event capture.

Rejected alternative:

One universal plugin with an installer that writes every host's files. That recreates the current monolithic installer problem and makes the adapter boundary blurry.

## Why keep `~/.introspect` as shared core?

Observation:

- Introspect already defines local state under `~/.introspect`. Source: `README.md:7`.
- Installer-created home state includes `AGENTS.md`, settings, skills, memory, feedback, runs, proposals, and models. Source: `scripts/install-hooks.sh:300-328`.
- Codex installs plugin bundles into cache paths, which are distribution artifacts, not durable user memory. Source: Codex plugin install/cache research lane plus Codex plugin docs in `source-inventory.md`.

Mechanism:

Prompt and memory updates must survive plugin reinstall, cache refresh, app upgrade, and host-specific uninstall. Plugin directories are code packages; `~/.introspect` is the user's local knowledge/history store.

Decision:

Adapters call into core. Core writes durable state.

## Why copy Cursor's loop shape but not its exact output?

Observation:

- Cursor's hook checks cadence and transcript mtimes before invoking the skill. Source: Cursor hook in `source-inventory.md`.
- Cursor's skill only delegates to an updater. Source: Cursor skill in `source-inventory.md`.
- Cursor's updater writes only learned preference/fact bullets in `AGENTS.md`. Source: Cursor updater in `source-inventory.md`.
- Introspect already routes to more surfaces than `AGENTS.md`: global prompt, project prompt, home memory, user skill, project skill, or no change. Source: `README.md:116`, `README.md:122-140`.

Mechanism:

Cursor's best idea is the control flow boundary, not the exact target file schema. Introspect needs the same simple cadence/updater shape while preserving richer target selection.

Decision:

Implement Introspect as a simple host skill/hook/updater path, but let the updater choose Introspect's existing target surfaces.

## Why keep classifier training separate?

Observation:

- Current Introspect pipeline uses local classifiers to decide wake triggers. Source: `README.md:109-120`.
- Cursor's continual-learning plugin is cadence-gated transcript mining and AGENTS updating, not model training. Source: Cursor raw files in `source-inventory.md`.

Mechanism:

Wake quality and memory quality are different loops. Combining them makes every user correction look like a model-training event and obscures the simpler fix: update the instruction surface.

Decision:

Classifier work is a separate "wake detection quality" project. Introspect updates prompts, memory, and skills.
