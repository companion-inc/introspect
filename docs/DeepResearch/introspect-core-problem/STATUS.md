# Status

Confidence: 88/100

Objective: Understand the real product problem Introspect is meant to solve, using local Codex/Claude conversations plus the current repo/runtime, and turn that into a durable architecture for routing trigger-word pain into the right agent surface.

Known facts:

- Introspect is currently described as a macOS app and hook engine for improving local Claude/Codex instructions from real trigger signals; its public/private split puts reusable app code in this repo and user-specific Introspect home state under `~/.introspect`. Source: `README.md:3`, `README.md:11`.
- The installed scanner is not a polling timer: the scanner LaunchAgent uses `RunAtLoad` and `WatchPaths` for `~/.codex/history.jsonl` and `~/.codex/sessions`, with no `StartInterval`; the health LaunchAgent uses `RunAtLoad` with no `StartInterval`. Sources: `/Users/advaitpaliwal/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist:42-52`, `/Users/advaitpaliwal/Library/LaunchAgents/ai.companion.introspect.health.plist:25-30`.
- The "wake every 0 seconds" symptom is real as repeated wake/noise, but not as a timer interval. The same current prompt was logged by the foreground hook and by the Codex transcript scanner, producing four trigger events for one user intent. Sources: `feedback/events.jsonl:4714-4717`, `feedback/reflector.log:12782-12805`.
- A deduped local corpus scan found 31,329 Codex user turns with 3,874 trigger turns and 4,325 Claude user turns with 886 trigger turns across 2025-09-07 to 2026-06-14. Source: command output, `python3` transcript dedupe scan run in this session.
- The biggest deduped trigger categories are question/confusion mode errors, explicit constraints ignored, missing prior context/docs, tech-specific routing, live-state verification failures, scope/background-work sprawl, and continue/resume pressure. Source: command output, `python3` transcript dedupe scan run in this session.
- Existing repo docs already choose the right layer split: `no_change`, `core_prompt`, `project_prompt`, `home_memory`, `skill_new`, `skill_update`, `project_skill_new`, `project_skill_update`, and `skill_prune`. Source: `README.md:81-82`, `docs/hermes-self-evolution-review.md:44-52`.
- Existing skill guidance says skills are scoped procedural memory, not a second global prompt, and casual profanity or external-system venting should produce no change. Source: `skills/skill-creator/SKILL.md:10-12`.
- During this research run, the background reflector first classified the current Introspect request as `no_change`, then later another retry used noisy aggregate trigger-rate reasoning to auto-revert an `AGENTS.md` line and create commit `be6bb08`. Source: `feedback/reflector.log` tail and `git show be6bb08` command output in this run.

Open questions:

- How much of the Codex scanner backstop is still needed after hook trust/reload behavior stabilizes in Desktop. The current code says it is needed because hooks can be skipped, but I did not run a fresh controlled hook-vs-scanner capture test.
- Whether the active UI should default to proposal/staging instead of auto-apply for all prompt/skill writes. The auto-created commit `be6bb08` makes this no longer theoretical.
- Whether transcript routing should use embeddings, keyword-first retrieval, or both. Current docs prefer keyword-first until routing becomes noisy; the deduped corpus suggests the index is already large enough to require at least clustering and near-miss tests before adding new skills.
- Whether to temporarily disable immediate reflection while a deep research session is active. The current live run showed unrelated Companion triggers repeatedly starting/retrying the reflector during this research pass.

Next action:

- Implement the next product layer as a curator pipeline: canonical event identity, per-project/session isolation, evidence bundle, classification, proposal, verification, and staged write.

Verification log:

- `plutil -p ~/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist`: confirmed `WatchPaths` plus `RunAtLoad`, no timer key.
- `plutil -p ~/Library/LaunchAgents/ai.companion.introspect.health.plist`: confirmed `RunAtLoad`, no timer key.
- `launchctl print gui/$(id -u)/ai.companion.introspect.codex-scanner`: confirmed state `not running`, trigger type `com.apple.launchd.WatchPaths`, `runs = 6` at the time checked.
- `./scripts/introspect-status.sh`: confirmed prompt links, hooks, scanner, health monitor, and skill validation; interrupted after it printed status because it was hanging on a later check. It printed `4719 total, 380 triggered` after interruption.
- Raw local transcript scan: 61,685 Codex user-message records and 7,523 Claude user-message records; this was intentionally superseded by the deduped scan because Codex stores duplicate user records.
- Deduped local transcript scan: 31,329 Codex user turns, 4,325 Claude user turns, 4,760 total trigger turns.
- `git show --stat --patch be6bb08 -- AGENTS.md`: confirmed the background reflector auto-created a commit deleting the explicit-constraints AGENTS rule.
- `kill 39530`: stopped the active reflector worker that remained after the auto-apply incident. A later scheduled retry state remained in `feedback/reflector-state.json`.

Mutation log:

- Created `docs/DeepResearch/introspect-core-problem/` using `deep-research/scripts/init_deep_research.py`.
- Updated this research package only by manual action.
- Separately, the live background reflector changed `AGENTS.md` and committed `be6bb08` while this research was in progress; I did not revert that generated commit.
