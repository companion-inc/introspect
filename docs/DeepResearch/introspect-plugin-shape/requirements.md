# Requirements

## Goal

Make Introspect feel like the host agent's native extension model instead of a separate universal runtime. The learning loop should be understandable as:

`host stop/cadence hook -> Introspect skill/command -> updater -> narrow AGENTS/skill/memory change -> verification/proposal artifact`

## Constraints

- Do not make classifier retraining part of the normal Introspect loop. Local Introspect currently uses classifiers for wake detection, but the simple Introspect path should update instruction/memory surfaces from transcript evidence. Sources: `README.md:109-120`, Cursor updater source inventory.
- Keep durable state under `~/.introspect`, not inside plugin caches. Introspect already treats `~/.introspect` as local state for prompts, events, scores, queues, diffs, proposals, and history. Source: `README.md:7`.
- Use each host's native packaging:
  - Codex plugin for Codex.
  - Claude Code plugin for Claude.
  - OpenCode JS/TS plugin plus native sidecars for OpenCode.
  - Cursor plugin shape if Cursor support is added.
- Preserve Introspect's layer router. Cursor writes only two sections in `AGENTS.md`, but Introspect already distinguishes global prompt, project prompt, memory, user skill, and project skill. Source: `README.md:116`, `README.md:122-140`.
- Keep prompts plain. Evidence, confidence, and source details belong in Introspect run artifacts, not in loaded `AGENTS.md` unless the actual learned behavior requires a concise instruction.

## Non-goals

- One universal plugin manifest.
- Running a heavy reflector on every stop.
- Training wake or assistant-boundary classifiers as part of every learning event.
- Moving all host config into Introspect-owned abstractions.
- Copying Cursor's exact two-section `AGENTS.md` format wholesale.

## Acceptance Criteria

- A Codex install can be represented as a real Codex plugin with bundled skill(s) and hook(s), while durable data still lands in `~/.introspect`.
- A Claude install can be represented as a real Claude plugin with bundled skill(s), hook(s), and optional updater agent/MCP.
- An OpenCode install can be represented as an OpenCode JS/TS plugin plus explicit sidecar installation for skills/rules.
- The core Introspect command can run without any host UI and can be called by each adapter.
- A no-op run produces a stable no-op message and updates the transcript index without changing prompt files.
- A high-signal correction creates one narrow prompt/memory/skill change or a proposal, with evidence in `~/.introspect/runs` or `~/.introspect/feedback`.
