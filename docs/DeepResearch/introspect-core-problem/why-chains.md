# Why-Chains

## Question: Why Did It Wake "Every 0 Seconds"?

Evidence:

- The installed Codex scanner LaunchAgent has `RunAtLoad` and `WatchPaths`, not `StartInterval`. Source: `/Users/advaitpaliwal/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist:42-52`.
- The health LaunchAgent has `RunAtLoad`, not `StartInterval`. Source: `/Users/advaitpaliwal/Library/LaunchAgents/ai.companion.introspect.health.plist:25-30`.
- `launchctl print` showed the scanner as `not running` with an FSEvents `WatchPaths` event trigger, not a resident loop. Source: command output in this run.
- The same current prompt was captured through the foreground hook and the Codex transcript scanner, producing four trigger records. Source: `feedback/events.jsonl:4714-4717`.
- The reflector log shows duplicate worker starts exiting under the lock and then one batch running. Source: `feedback/reflector.log:12782-12789`.

Mechanism:

The scanner is event-driven, but it watches a hot directory: `~/.codex/sessions`. Active Codex sessions append JSONL records frequently. The foreground hook also logs the prompt. Without canonical event identity across hook and scanner paths, one user intent can produce multiple event rows and multiple worker start attempts. The lock prevents simultaneous reflectors, but it does not prevent wake noise or duplicate queued events.

Rejected alternatives:

- "It is polling every 0 seconds": rejected by installed plist and launchd state. No timer key was present.
- "Delete the scanner": rejected because repo comments and README say Codex Desktop hooks can be missed until hook trust/reload catches up. Source: `README.md:51`, `scripts/install-hooks.sh:431-434`.

Decision:

Keep the scanner backstop, but add canonical event dedupe and narrow triggering. The scanner should detect new canonical user prompts, not treat every session-file write as meaningful work. The worker should collapse hook and scanner records by transcript path, transcript line or content hash, session id, and timestamp window before queueing or reflecting.

Verification:

- Reproduce one Codex prompt with both hook and scanner enabled.
- Assert one canonical event and one queued item.
- Assert repeated file writes with no new user prompt produce zero queued events and no worker kick.

Remaining risk:

- If Codex Desktop changes transcript shape, path/line identity may drift. Store both line-based and content-hash identities.

## Question: What Is Introspect Actually Meant To Solve?

Evidence:

- The README says Introspect improves local Claude/Codex agent instructions from real trigger signals. Source: `README.md:3`.
- The repo explicitly says agent memory is a routing problem, not one giant prompt. Source: `README.md:87-90`.
- The local deduped corpus scan found 35,654 user turns across Codex and Claude and 4,760 trigger turns.
- The highest trigger categories are not a single technology; they are repeated failure shapes: question/confusion mode errors, explicit constraints ignored, missing prior context/docs, tech-specific routing, live-state verification failures, scope/background-work sprawl, and continue/resume pressure. Source: deduped transcript category scan in this run.
- Existing docs say `no_change` is often correct and one trigger batch should yield one decision. Source: `docs/hermes-self-evolution-review.md:54-58`.

Mechanism:

The user is using agents as a cross-project operating layer. Negative emotion is not the product problem by itself; it is a compressed operator signal that something in the agent operating loop failed or is at risk of failing. The repeated failures are mostly not "bad tone." They are wrong mode, lost context, skipped research, ignored constraints, no live verification, bad scope control, and missing reusable technical procedures.

Rejected alternatives:

- "Make a better profanity detector": rejected because many triggers are false positives and the existing reflector correctly classified the current request as `no_change`. Source: `feedback/reflector.log:12790-12805`.
- "Append more global prompt rules": rejected because the repo and skill guidance warn against prompt bloat and say reusable lessons belong in skills or project surfaces. Sources: `README.md:102-108`, `skills/skill-creator/SKILL.md:10-12`.

Decision:

Introspect should be an evidence-backed curator that turns repeated operator pain into the narrowest durable improvement. It should maintain a compact global prompt, project prompts for repo facts, project skills for repeatable repo procedures, user skills for cross-project workflows, home memory for durable user/local facts, and hooks for deterministic guarantees.

Verification:

- For each proposed change, require a source bundle and a positive/near-miss behavior probe.
- Track false-positive rates and no-change decisions as success, not wasted work.

Remaining risk:

- Heuristic category labels are discovery aids. Final classification must read transcript context and source evidence.

## Question: Where Should Repeated Tech Complaints File Themselves?

Evidence:

- Project skills belong beside the codebase, while global skills should stay user-wide only when reusable across projects. Source: `README.md:91-96`.
- Skill guidance says read the failure transcript, index, and closest existing skill before creating or changing a skill. Source: `skills/skill-creator/SKILL.md:18-20`.
- The source map says update failed skills rather than duplicating and keep compactness as an objective. Source: `skills/skill-creator/references/source-map.md:136-154`.
- Deduped transcript categories included 979 tech-specific routing events, with Companion and Iris as major hotspots.

Mechanism:

A repeated technology complaint should become a routing problem:

- If it names one repo's architecture or conventions, file it into that repo's `AGENTS.md` or project skill.
- If it names a cross-project tool workflow, file it into a user-wide skill.
- If it names a deterministic setup or validation action, file it into a script or hook.
- If it is just frustration with an external dependency and no agent behavior changed, file it as `no_change`.

Rejected alternatives:

- "Create a skill for each technology word": rejected because the skill index would become noisy and the source map says compactness matters.
- "Put all technology preferences in the global prompt": rejected because those lessons are not always-on across every project.

Decision:

Add a tech-routing stage before write classification: extract entities from the trigger event, map them to existing skills/project surfaces, read the closest matches, then choose update/new/no-change.

Verification:

- Feed examples mentioning React, Vercel AI SDK, Stripe, Cloudflare, SwiftUI, Gmail, and iMessage.
- Check that each routes to an existing skill/project surface when one exists, and creates no duplicate skill.

Remaining risk:

- Entity extraction from casual text can be noisy. Use transcript context and repo path as stronger signals than the trigger phrase alone.
