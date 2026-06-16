# Architecture

## Ideal Product

Introspect is a local agent-memory curator. It watches agent conversations for trigger signals, reads the relevant transcript and repo context, and turns repeated operator pain into the smallest durable change that will prevent the next similar failure.

It should feel like:

- A flight recorder for Claude/Codex work across projects.
- A triage queue for high-friction agent behavior.
- A routing engine for global prompt, project prompt, home memory, skills, and hooks.
- A proposal/staging UI for changes that affect future agents.

It should not feel like:

- Another agent interrupting active work.
- A profanity alarm.
- A prompt-bloat machine.
- A global process that wakes constantly without explaining why.

## System Shape

```text
Claude/Codex user prompt
  -> foreground hook event
  -> optional Codex transcript scanner backstop
  -> canonical event dedupe
  -> per-session/project batch
  -> evidence bundle
  -> classifier
  -> proposed target operation
  -> validation/probe
  -> staged diff or no_change record
  -> app Runs/Inbox surface
```

## Runtime Boundaries

- Hooks and scanner capture signals only. They should not decide what to change.
- Worker/curator owns batching, evidence gathering, classification, and proposal generation.
- App/UI owns visibility, review, approval, and rollback.
- Introspect home owns private user state, trigger words, pending proposals, and personal skills.
- Project repos own project prompts and project skills.

## Storage, Config, Secrets

- Public reusable engine: this repo.
- Private Introspect home: `~/.introspect`.
- Runtime feedback: `feedback/` while local and ignored.
- Installed launchd state: `~/Library/LaunchAgents/ai.companion.introspect.*.plist`.
- No secret values should be written into events, bundles, or staged changes.

## Event Flow

### Capture

Foreground hooks log prompt metadata and exact trigger-word matches. Codex transcript scanner catches prompts missed by Desktop hooks. Sources: `hooks/trigger-reflect.sh:146-181`, `README.md:79`.

Required change: add a canonical event id across hook and scanner paths.

### Canonicalization

One user prompt can have many source records but only one canonical event. Merge by:

- `session_id`
- `cwd`
- `transcript_path`
- `transcript_line` when present
- normalized prompt hash
- timestamp window

### Batching

Current worker behavior has global cooldown, session cooldown, and scheduled retry. Source: `hooks/trigger-worker.py:43-47`, `hooks/trigger-worker.py:975-1015`.

Required change:

- Batch by project/session first.
- Avoid letting one project's cooldown/retry loop interrupt unrelated active work.
- Expose delayed/requeued events in the UI.
- Add a quiet/manual mode that queues but does not auto-run while the user is actively deep researching.

### Evidence Bundle

Each classifier run needs:

- Trigger event and normalized prompt.
- Surrounding transcript turns.
- Current project path and loaded agent surfaces.
- Closest existing skills and index entries.
- Recent related trigger history for the same project/session.
- Current prompt version and trigger-rate comparison.
- Any live runtime evidence needed by the failure class.

This matches existing guidance: read transcript/event, index, closest skills, and relevant sources before changing skills. Source: `skills/skill-creator/SKILL.md:18-36`.

### Classifier

Targets:

- `no_change`
- `core_prompt`
- `project_prompt`
- `home_memory`
- `skill_new`
- `skill_update`
- `project_skill_new`
- `project_skill_update`
- `skill_prune`
- `hook_or_script`

The classifier must emit confidence, evidence, rejected alternatives, proposed files, verification plan, and apply mode.

## Tool Routing

Routing order:

1. Current project skills.
2. Current project prompt.
3. User-wide skills.
4. User home memory.
5. Global prompt.
6. Hook/script only for deterministic requirements.

Skill creation rule:

- Read `skills/index.json` and closest existing skills first.
- Update before creating when a close fit exists.
- Add positive and near-miss routing examples for broad skills.
- Prune/narrow stale or duplicate skills.

Sources: `skills/skill-creator/SKILL.md:18-20`, `skills/skill-creator/SKILL.md:60-76`, `skills/skill-creator/references/source-map.md:136-168`.

## UI Boundaries

Minimum useful screens:

- Status: prompt links, hooks, scanner, health, queued events, active worker.
- Runs: event clusters, source records, classification, output, diffs, verification.
- Skills: inventory by provider/scope, duplicates, warnings, loaded path, frontmatter, token estimate.
- Projects: roots, agent files, project skills, local prompt state.
- Pending Changes: staged prompt/skill/memory/hook proposals with approve/reject/apply.

Source: `docs/skill-manager-reference-review.md:14-30`.

## Failure Modes

- Duplicate event paths make one prompt look like many failures.
- Global cooldown causes unrelated project triggers to requeue and run later during another task.
- Broad trigger words capture casual register or external-system pain.
- Skill creation without routing creates noisy duplicates.
- Global prompt edits overfit one project and make other work worse.
- Auto-apply without staging makes the curator itself another source of anxiety.

## Product Decision

The next implementation should prioritize the control plane before adding more prompt or skill intelligence:

1. Canonical event dedupe.
2. Per-project/session batching.
3. Quiet/staged mode.
4. Evidence bundle schema.
5. Classification/proposal UI.
6. Skill-router upgrade.
