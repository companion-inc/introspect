# Status

Confidence: 94/100.

Decision: build Introspect as host-native adapters over a shared `~/.introspect` core, not as one universal plugin package and not as classifier retraining.

Implemented in this pass:

- `introspect run`: safe no-op/indexing core command that writes cadence state under `~/.introspect/introspect/<host>/` and run artifacts under `~/.introspect/runs/<run-id>/`.
- `plugins/introspect/`: Codex plugin adapter skeleton with manifest, bundled Stop hook file, hook wrapper script, and `introspect` skill.
- `.agents/plugins/marketplace.json`: repo-local marketplace entry for the Codex adapter.
- `scripts/test-introspect-run.py` and `scripts/test-codex-plugin-adapter.py`: deterministic tests for core command and Codex hook wrapper.
- The paused classifier retraining edits were removed from this worktree; Introspect now stays separate from wake model training.

Verified locally on 2026-06-22:

- Codex: repo marketplace registered as `introspect-local`, `introspect@introspect-local` installed and enabled in real `~/.codex`, cached hook executed successfully against isolated state, and `codex exec` returned `SUBAGENTS=yes ACCESS=perform`.
- Claude: `claude` 2.1.185 is usable, prompt links point at Introspect, behavior probe returned `AUTHZ=perform`, and `introspect run --host claude` worked against isolated dummy transcript state.
- OpenCode: prompt link points at Introspect and `introspect run --host opencode` worked against isolated dummy transcript state. Live model conversation is blocked by local OpenCode runtime/auth: Homebrew `opencode` crashes on missing `libsimdjson.29.dylib`; fallback binaries start but OpenAI refresh returns `401`, Google has no Antigravity account, and the older Bun binary fails in `oh-my-openagent` plugin init.

Current recommendation:

- Keep `introspect-core` as the durable store, transcript/index layer, redaction layer, target router, and evidence artifact writer. Introspect already defines local state under `~/.introspect` and routes learning to global prompt, project prompt, home memory, user skill, project skill, or no change. Sources: `README.md:3-7`, `README.md:109-120`, `README.md:122-140`.
- Ship separate host adapters:
  - Codex: `.codex-plugin/plugin.json`, bundled skill(s), bundled `hooks/hooks.json`, optional MCP for status/diff/proposal tools. Codex docs say plugins package reusable skills and can bundle lifecycle hooks, MCP, and apps. Sources: Codex manual `codex-manual.md:7402-7405`, `codex-manual.md:10723-10728`, `codex-manual.md:11159-11185`, `codex-manual.md:11825-11837`.
  - Claude Code: real Claude plugin with `.claude-plugin/plugin.json`, skills, hooks, optional agents/MCP. Research lane found Claude has first-class plugin bundles containing skills, agents, hooks, MCP servers, LSP servers, monitors, and marketplaces. Sources: Claude docs cited in `source-inventory.md`.
  - OpenCode: executable JS/TS plugin plus native sidecars for `AGENTS.md`, skills, commands, or tools. Research lane found OpenCode plugins are executable JS/TS modules or npm packages, while durable rules/skills/commands/agents remain separate native surfaces. Sources: OpenCode docs cited in `source-inventory.md`.
  - Cursor: use its continual-learning plugin as reference: stop hook cadence gate, orchestration skill, updater agent, incremental transcript index, plain durable bullets. Sources: Cursor raw files cited in `source-inventory.md`.

Open questions:

- Exact Claude plugin manifest fields should be rechecked immediately before implementation because Claude Code plugin docs are still moving.
- Exact OpenCode plugin hook event names should be verified from current `packages/plugin/src/index.ts` or docs before coding.
- Codex plugin docs and local `plugin-creator` helper conflict on hooks: current docs/runtime support plugin hooks, while the local helper validator was reported stale. Implementation must use current Codex docs/runtime and update or bypass stale validation.

Next action:

1. Split the growing inline `bin/introspect` run logic into a small core module once it starts applying changes instead of only indexing/no-oping.
2. Add the updater that proposes or applies narrow AGENTS/skill/memory changes from changed transcripts.
3. Add Claude plugin adapter because Claude has a richer native plugin bundle.
4. Add OpenCode adapter as an executable JS/TS plugin plus native skill/rules install.
