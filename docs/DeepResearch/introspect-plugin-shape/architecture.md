# Architecture

## Recommended Shape

```text
                 +-----------------------+
Codex plugin --->|                       |
Claude plugin -->|  introspect-core CLI  |--> ~/.introspect/AGENTS.md
OpenCode plugin >|                       |--> ~/.introspect/memory/
Cursor plugin -->|                       |--> ~/.introspect/skills/
                 +-----------------------+--> ~/.introspect/runs/
                            |
                            v
             transcript index + redaction + target router
```

## Shared Core

`introspect-core` owns:

- transcript discovery/indexing for supported hosts
- redaction
- cadence state
- durable no-op detection
- target routing across prompt, memory, user skill, project skill, and no change
- evidence artifacts under `~/.introspect`
- deterministic checks and behavior probes

## Host Adapters

Codex adapter:

- `.codex-plugin/plugin.json`
- `skills/introspect/SKILL.md`
- `hooks/hooks.json`
- hook command calls `introspect run --host codex --event stop`
- optional MCP for status, runs, diffs, proposals

Claude adapter:

- `.claude-plugin/plugin.json`
- `skills/introspect/SKILL.md`
- `hooks/hooks.json`
- optional Claude-native updater agent if the current plugin spec supports bundling it cleanly
- optional MCP for proposal review and run inspection

OpenCode adapter:

- JS/TS plugin package such as `opencode-introspect`
- hook/event handlers call `introspect run --host opencode`
- sidecar installer writes OpenCode-native `AGENTS.md`, skills, and commands only where needed

Cursor adapter:

- `.cursor-plugin/plugin.json`
- `hooks/continual-learning-stop.ts`
- `skills/continual-learning/SKILL.md`
- updater agent modeled after Cursor reference, but target router calls Introspect core

## Minimal V1 Control Flow

1. Host stop hook runs a cheap cadence check.
2. Hook exits unless the run is root/completed, generation is new, cadence has passed, and transcript mtime advanced.
3. Hook invokes host skill or core command.
4. Updater reads only changed transcripts since the index.
5. Updater extracts durable preference/fact/procedure deltas.
6. Router chooses target:
   - global prompt for cross-project behavior
   - project prompt for repo-specific behavior
   - home memory for durable private facts
   - user/project skill for repeatable workflow
   - no change
7. Core writes exact diff/proposal and updates the index.
8. Adapter reports either no-op or changed target.
