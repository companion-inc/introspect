# Verification Matrix

## Research Verification

- Codex manual refreshed through OpenAI docs helper on 2026-06-22. Evidence: helper output named `codex-manual.md` and outline paths.
- Codex plugin, skill, and hook claims checked against current manual lines in `source-inventory.md`.
- Cursor continual-learning reference checked against raw GitHub files through a subagent lane.
- Claude Code and OpenCode standards checked through primary docs by a subagent lane.
- Local Introspect behavior checked from `README.md`, `scripts/install-hooks.sh`, `hooks/trigger-reflect.sh`, `hooks/trigger-worker.py`, and `hooks/codex-transcript-scan.py`.

## Implementation Verification To Run Later

Completed in this pass:

- `./bin/introspect --help`
- `./bin/introspect run --help`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-introspect-run.py`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-codex-plugin-adapter.py`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m py_compile bin/introspect plugins/introspect/scripts/introspect-stop.py scripts/test-introspect-run.py scripts/test-codex-plugin-adapter.py`
- `./scripts/test-install-paths.sh`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-trigger-words.py`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-surface-scopes.py`
- `PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/test-reflector-prompt-contract.py`
- `INTROSPECT_SKILLS_DIR="$PWD/skills" PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 scripts/validate-skills.py`
- `./scripts/test-release-e2e.sh`
- `jq . .agents/plugins/marketplace.json plugins/introspect/.codex-plugin/plugin.json plugins/introspect/hooks/hooks.json`
- `/Library/Frameworks/Python.framework/Versions/3.14/bin/python3 /Users/advaitpaliwal/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py plugins/introspect`

Plugin validator note: `/usr/bin/python3` and the bundled workspace Python lacked `PyYAML`, so validation used the local framework Python where `PyYAML 6.0.3` is installed.

Codex adapter:

- Validate `.codex-plugin/plugin.json` against current Codex runtime, not only the stale local helper: done with `codex plugin list`, `codex plugin add`, cached plugin inspection, and plugin validator on 2026-06-22.
- Install through a local marketplace and verify the plugin appears in Codex: done in real `~/.codex`; `introspect@introspect-local` installed and enabled.
- Run plugin-bundled hook: done through the installed cached hook with isolated `INTROSPECT_HOME`; it produced a `stop` run with `classifier_training=false` and `mutated_targets=[]`.
- Confirm stop hook writes only cadence state on no-op: done for the no-op path; the run wrote only Introspect state/index/run artifacts.
- Talk to Codex with the loaded prompt: done with `codex exec`; result was `SUBAGENTS=yes ACCESS=perform`.
- Confirm high-signal transcript update changes the selected `~/.introspect` target.

Claude adapter:

- Validate `.claude-plugin/plugin.json` against Claude Code plugin docs/runtime.
- Install plugin into Claude Code.
- Confirm hook fires on `Stop` and passes transcript/session identity to core.
- Confirm bundled skill invokes core updater.
- Prompt-link and behavior probe: done on 2026-06-22; `claude -p` with project/local settings returned `AUTHZ=perform` for an explicit user-owned sharing request.
- `introspect run --host claude`: done against an isolated dummy transcript/state; result was `status=no_change`, `changed_transcript_count=1`, `classifier_training=false`, `mutated_targets=[]`.

OpenCode adapter:

- Install JS/TS plugin from local package.
- Confirm plugin hooks fire and can call core.
- Confirm native sidecar skill/rules files are discovered once, without duplicate skill names.
- Prompt-link state: done; `~/.config/opencode/AGENTS.md` points at `~/.introspect/AGENTS.md`.
- `introspect run --host opencode`: done against an isolated dummy transcript/state; result was `status=no_change`, `changed_transcript_count=1`, `classifier_training=false`, `mutated_targets=[]`.
- Live OpenCode model probe: blocked. `/opt/homebrew/bin/opencode` crashes on missing `libsimdjson.29.dylib`; fallback binaries start, but OpenAI refresh returns `401`, Google reports no Antigravity account, and the older Bun binary fails in `oh-my-openagent` plugin init.

Core:

- Unit-test cadence gates: covered by `scripts/test-introspect-run.py`.
- Unit-test transcript index idempotence: covered by `scripts/test-introspect-run.py`.
- Unit-test redaction.
- Probe a real failure transcript that should update prompt.
- Probe a transcript with quoted failures that should not update prompt.
- Confirm no classifier/model files change during Introspect runs: covered by run outputs and release test; `classifier_training=false` and no model files were touched.

## Current Unverified Items

- Exact Claude plugin manifest schema fields at implementation time.
- Exact OpenCode plugin event names at implementation time.
- Real Codex hook trust UI was not clicked; the installed hook was executed directly from the cached plugin path with isolated state.
- Live OpenCode model conversation remains blocked by local OpenCode auth/runtime issues.
