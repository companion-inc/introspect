# Requirements

## Goal

Introspect should solve the problem of too much agent/computer activity spread across many projects by consolidating repeated negative operator signals into the narrowest useful durable layer:

1. `no_change` when the signal is casual register, external-system pain, or unsupported.
2. Global agent prompt when the lesson is always-on across nearly every task.
3. Project prompt when the lesson is repo-specific state, architecture, or workflow policy.
4. Home memory when the lesson is a durable user/local-machine preference.
5. User-wide or project-local skills when the lesson is a repeatable procedure, source map, or tool workflow.
6. Hooks/scripts when the behavior must happen deterministically.

Sources: `README.md:87-110`, `skills/skill-creator/references/source-map.md:174-181`.

## Product Shape

Introspect is a local curator, not a chatbot and not a raw profanity detector.

- Input: user prompts and transcript context from Claude, Codex, and eventually other agent tools.
- Signal: local classifier wake events plus non-trigger usage stats, optional review-term metadata, project/cwd, session id, transcript path, and prior surface diffs.
- Classifier: reads the triggering conversation and source evidence, then chooses one target operation.
- Output: either `no_change` or a staged, source-backed proposal to update prompt/project/memory/skill/hook state.
- UI: shows event clusters, source transcript, classification, proposed diff, verification result, and whether the change was applied.

Sources: `README.md:72-83`, `docs/skill-manager-reference-review.md:14-30`.

## Non-Goals

- Do not append every emotional phrase to `AGENTS.md`.
- Do not create one narrow skill per outburst.
- Do not treat a review term as proof of an agent failure.
- Do not silently mutate shared/global skills for project-specific failures.
- Do not train adapters in v1.
- Do not rely on raw transcript record counts without deduping canonical user turns.

Sources: `docs/hermes-self-evolution-review.md:31-38`, `docs/hermes-self-evolution-review.md:54-61`, `skills/skill-creator/SKILL.md:10-12`.

## Naming Constraints

- Use current repo vocabulary: trigger, classifier wake event, optional review terms, Runs, reflector run.
- Do not reintroduce old "frustration" product labels in new surfaces.
- Use `activation_signals` for skill routing metadata.

Sources: `hooks/trigger-worker.py:833-834`, `skills/skill-creator/SKILL.md:73`.

## Inputs

- Foreground hook event from Claude or Codex.
- Codex transcript scanner backstop event.
- Transcript context around the user prompt.
- Current working directory and project root.
- Global/project prompt files.
- Skill index and nearest skill bodies.
- Recent trigger history and surface diffs.
- Runtime evidence when the failure concerns live behavior.

## Outputs

- Canonical event record.
- Batch record.
- Evidence bundle.
- Classifier decision.
- `no_change` record or staged proposal.
- Surface diff and verification record when applied.

## Acceptance Criteria

- A single user prompt captured by both hook and scanner becomes one canonical event, not four reflector events. Evidence: current duplicate event lines `feedback/events.jsonl:4714-4717`.
- The scanner remains a backstop for missed Codex Desktop hooks, but it does not behave like a noisy poller. Evidence: installed scanner uses `WatchPaths`, not `StartInterval`, in `/Users/advaitpaliwal/Library/LaunchAgents/ai.companion.introspect.codex-scanner.plist:42-52`.
- The system can show why a trigger became `no_change`, `core_prompt`, `project_prompt`, `home_memory`, `skill_new`, `skill_update`, `project_skill_new`, `project_skill_update`, `skill_prune`, or hook/script work.
- A technology-specific repeated complaint routes to the closest existing project/user skill before proposing a new one. Source: `skills/skill-creator/SKILL.md:18-20`, `skills/skill-creator/references/source-map.md:136-139`.
- A project-specific complaint routes to project prompt or project skill, not the global prompt, unless the same failure shape repeats across projects. Source: `docs/hermes-self-evolution-review.md:44-52`.
- A visible run includes enough evidence for the user to trust the action: event text, transcript path, classifier reason, chosen target, diff, validation, and rollback path.

## Approval Boundaries

- Research and classification can run automatically.
- `no_change` records can be applied automatically.
- Prompt/skill/project-memory writes should be staged by default once the UI has pending-change support. The Hermes review says silent autonomous skill edits are too much power for v1 unless explicitly enabled. Source: `docs/hermes-self-evolution-review.md:33-35`, `docs/hermes-self-evolution-review.md:60`.
- Deterministic hook changes should require stronger verification than prompt/skill changes because they can affect every agent turn.
