# Codex Introspect Benchmark Status

Understanding: 91/100

Objective: Compare Codex CLI against the same Codex CLI with Introspect installed, using copied Codex auth and Daytona sandboxes, then hillclimb Introspect prompt/hook behavior against scored tasks.

Settled:

- Daytona auth works through `DAYTONA_API_KEY`.
- Daytona SDK sandbox creation and `sandbox.process.exec` work from the local Python SDK.
- The remote benchmark can install and run Codex CLI `0.142.5` inside Daytona.
- The benchmark runner copies `auth.json` and `installation_id` into isolated temp `CODEX_HOME` directories.
- The smoke benchmark passed both arms in Daytona, and the Introspect arm logged two hook events.
- The core behavior suite passed both arms in Daytona: 4/4 for Codex and 4/4 for Codex+Introspect. That suite is useful as a regression guard, but it is too easy to show a benefit.
- The hook suite passed in Daytona after the prompt-routing hillclimb: Codex 0/2, Codex+Introspect 2/2. Each Introspect task logged three hook events and one wake.

Current hillclimb:

- Fresh Introspect installs had a near-empty global prompt, so the first improvement is a compact default behavior core in `templates/default-AGENTS.md`.
- The benchmark runner now supports inline fixture files and setup commands, allowing small scored tasks without an external repo checkout.
- `bench/codex-introspect-core.jsonl` adds the first behavior suite: answer-first, source-grounded naming, local secret retrieval, and preserving user-authored values.
- The benchmark runner now supports `new_thread: true` turns so a correction can wake Introspect and a later fresh Codex session can test whether the learned prompt/project guidance actually persists.
- `bench/codex-introspect-hook.jsonl` adds two hook-specific tasks: learn a repo benchmark-manifest convention and learn a repo handoff-note convention from correction turns, then apply each convention in a fresh session.
- Local hillclimb failure found the real bug: the reflector routed a repo artifact-schema convention to home memory, which future Codex sessions do not load. The fix is in `hooks/trigger-worker.py`: repo file paths, artifact schemas, command conventions, and workflow rules route to project prompt/project skill, not home memory.
- The manifest benchmark now scores runner-compatible JSONL: `files` must be an object/map and each `turns` item must use `prompt`, not chat-style `role`/`content`.

Next:

- Keep this suite as the first regression gate for future Introspect hook changes.
- Add real-repo coding tasks next; current hook tasks prove persistent feedback routing, not broad coding quality.
