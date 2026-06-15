# Handoff

## Read First

1. `docs/DeepResearch/introspect-core-problem/STATUS.md`
2. `docs/DeepResearch/introspect-core-problem/why-chains.md`
3. `docs/DeepResearch/introspect-core-problem/architecture.md`
4. `docs/DeepResearch/introspect-core-problem/runtime-contracts.md`

## Confidence

88/100.

I verified the current repo design, installed LaunchAgents, feedback logs, reflector behavior, a deduped local transcript scan, and an actual unsafe auto-apply incident during the run. I did not run a controlled hook-vs-scanner capture test or implement the classifier.

## Done

- Answered the wake question with runtime evidence: scanner and health monitor are not timer polls; repeated wake came from watched Codex files plus duplicate hook/scanner event paths.
- Scanned local Codex and Claude transcript stores from 2025-09-07 through 2026-06-14.
- Produced deduped counts by tool and top project.
- Clustered trigger turns into product-relevant buckets.
- Confirmed the current request was correctly classified by the live reflector as `no_change`.
- Observed the live reflector later auto-create commit `be6bb08`, reverting an `AGENTS.md` rule based on noisy aggregate trigger-rate reasoning.
- Stopped the active reflector worker after that auto-apply incident.
- Wrote the product architecture and runtime contracts for canonical event routing.

## Not Done

- No code changes to hooks, worker, app, prompts, or skills.
- I did not undo the generated `be6bb08` commit; it remains current git history and should be handled explicitly.
- No controlled replay test proving the exact current Codex hook miss rate.
- No implementation of canonical event ids.
- No UI proposal/staging implementation.
- No classifier prompt or eval suite.

## Do Next

1. Implement canonical event dedupe before queueing:
   - Merge foreground hook and Codex scanner records by session id, transcript path/line, prompt hash, and timestamp window.
   - Add a regression test using the current duplicate pattern in `feedback/events.jsonl:4714-4717`.
2. Add per-project/session queue isolation:
   - Make global cooldown visible but not dominant.
   - Prevent unrelated Companion triggers from repeatedly waking the curator during another active task.
3. Add quiet/manual mode:
   - Queue events and show them in the app without spawning a reflector.
   - Use this during deep research or when the user complains about background wake noise.
4. Build the evidence bundle:
   - Pull transcript context, loaded surfaces, closest skills, recent related triggers, and current prompt version into one JSON record.
5. Build staged proposals:
   - `no_change` can auto-record.
   - Prompt/skill/memory/hook changes should stage with diff, evidence, and verification.
   - Do this before allowing any more auto-apply prompt or skill writes.
6. Add routing probes:
   - React state-management complaint in Companion should route to project skill or existing React skill, not global prompt.
   - "Why did it wake" should route to runtime/worker docs or hook fix, not a new prompt rule.
   - Casual product-domain venting should route to `no_change`.

## Do Not Repeat

- Do not treat trigger count alone as failure count.
- Do not add global prompt lines for every repeated complaint.
- Do not create duplicate narrow skills before checking `skills/index.json` and closest skill bodies.
- Do not call scanner behavior "polling" unless a timer key or loop is actually present.
- Do not ignore `no_change`; it is the safety valve that keeps Introspect from becoming prompt bloat.

## Commands

```bash
plutil -p ~/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist
plutil -p ~/Library/LaunchAgents/ai.companion.introspect.health.plist
launchctl print gui/$(id -u)/ai.companion.introspect.codex-scanner
./scripts/introspect-status.sh
INTROSPECT_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
./scripts/test-trigger-words.py
```

## Blockers

- The live reflector can still spawn while unrelated active work is underway. It auto-created commit `be6bb08` during this research pass.
- `feedback/reflector-state.json` still recorded a scheduled retry after I killed the active worker. The next implementation should clear scheduled retry state through a real control path, not ad hoc file edits.
