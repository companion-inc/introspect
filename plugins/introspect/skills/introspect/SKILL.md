---
name: introspect
description: Run Introspect for Codex sessions when the user asks Introspect to inspect recent corrections, update agent instructions, or report what it would remember.
---

# Introspect

Use this skill when the user wants Introspect to inspect recent Codex sessions, update durable agent instructions, or report what Introspect would remember.

## Procedure

1. In the Introspect repo, run `./bin/introspect run --host codex --event manual --force`. Outside this repo, run `introspect run --host codex --event manual --force` only when the `introspect` executable is on `PATH`.
2. Read the printed run path.
3. Inspect `result.json` and `summary.md` under that run path when the user asks what changed.
4. Report whether the run changed any prompt, memory, or skill target.

## Boundaries

- Introspect updates instruction, memory, or skill surfaces. It does not train wake classifiers.
- A no-op result is valid when there are no high-signal durable updates.
- Durable state belongs under `~/.introspect`, not inside the plugin cache.
