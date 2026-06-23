# Handoff

Read first:

1. `docs/DeepResearch/introspect-plugin-shape/STATUS.md`
2. `docs/DeepResearch/introspect-plugin-shape/why-chains.md`
3. `docs/DeepResearch/introspect-plugin-shape/architecture.md`
4. `README.md:109-140`
5. Cursor continual-learning raw files listed in `source-inventory.md`

Decision:

Build separate host-native adapters over shared `introspect-core`.

Do not build:

- one universal plugin package
- classifier retraining as the default Introspect loop
- a heavy reflector on every stop

Implemented:

- Core no-op/index command: `introspect run`.
- Codex adapter skeleton: `plugins/introspect/`.
- Repo-local Codex marketplace: `.agents/plugins/marketplace.json`.
- Core and adapter tests: `scripts/test-introspect-run.py`, `scripts/test-codex-plugin-adapter.py`.
- Classifier retraining edits isolated out of this branch.

Next build order:

1. Add the actual updater behind `introspect run`.
2. Split core logic out of `bin/introspect` when the updater grows beyond indexing/no-op artifacts.
3. Add Claude plugin adapter.
4. Add OpenCode adapter.
5. Add Cursor adapter only after Codex/Claude/OpenCode boundaries are stable.

Main implementation risk:

The current repo is already a broad cross-host installer and classifier-driven reflector. The plugin work should not deepen that monolith. Keep adapters thin and move shared behavior into a core command that each host can call.
