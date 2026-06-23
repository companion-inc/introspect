# Runtime Contracts

## Core Command

Proposed command:

```bash
introspect run \
  --host codex|claude|opencode|cursor \
  --event stop|manual \
  --cwd "$PWD" \
  --transcript-path PATH \
  --session-id ID \
  --apply auto|proposal|never
```

Inputs:

- host name
- event type
- current workspace
- transcript locator when available
- session/generation id when available
- apply mode

Outputs:

- exit `0` with no-op or successful update
- exit nonzero only for infrastructure failure
- machine-readable JSON line in `~/.introspect/runs/<run-id>/result.json`
- human-readable summary in `~/.introspect/runs/<run-id>/summary.md`

No-op text:

```text
No high-signal memory updates.
```

## Cadence State

State path:

```text
~/.introspect/introspect/<host>/state.json
~/.introspect/introspect/<host>/transcript-index.json
```

State fields:

- last successful run timestamp
- last processed generation/session id
- completed root turn count since last run
- transcript paths with mtimes and offsets/hashes
- last changed target hash

## Target Contract

The updater may choose exactly one primary target per learning item:

- `global_agents`: `~/.introspect/AGENTS.md`
- `project_agents`: nearest repo `AGENTS.md`
- `project_claude`: project `CLAUDE.md` only when Claude needs extra guidance beyond `AGENTS.md`
- `home_memory`: `~/.introspect/memory/`
- `user_skill`: `~/.introspect/skills/<skill>/SKILL.md`
- `project_skill`: `.agents/skills/<skill>/SKILL.md`, `.claude/skills/<skill>/SKILL.md`, or OpenCode-native skill path
- `no_change`

Evidence and confidence belong in run artifacts, not in loaded prompt text.

## Adapter Contract

Adapters must:

- use host-native plugin/hook/skill packaging
- pass host identity and transcript locator to core
- keep host-specific cache/install files disposable
- never store durable learned memory in plugin cache
- avoid training classifiers during Introspect runs
- avoid running a heavy update on every stop; every stop may check cadence cheaply
