# Runtime Contracts

## Canonical Event

```json
{
  "canonical_event_id": "sha256:...",
  "created_at": "2026-06-14T00:00:00Z",
  "tool": "codex|claude",
  "session_id": "...",
  "cwd": "/absolute/project/path",
  "transcript_path": "/absolute/transcript/path",
  "transcript_line": 123,
  "prompt_hash": "sha256:...",
  "prompt_excerpt": "short redacted excerpt",
  "matched_words": ["..."],
  "source_records": [
    {
      "source": "foreground_hook|codex_transcript_scan",
      "events_line": 4714,
      "observed_at": "2026-06-13T23:58:58Z",
      "dedupe_key": "..."
    }
  ],
  "dedupe_status": "canonical|merged|ignored",
  "dedupe_reason": "same session, same prompt hash, same timestamp window"
}
```

Contract:

- `prompt_hash` is over normalized user-visible prompt text.
- `source_records` can grow, but queueing happens once per canonical event.
- Assistant messages, Codex file/context wrappers, control messages, pasted context, and reflector prompts are excluded before canonicalization.
- Trigger-rate stats and worker queue intake count direct user messages only and collapse hook/scanner duplicate observations.

## Repetition Pressure

```json
{
  "wake_reason": "repetition_pressure",
  "repetition_pressure": {
    "version": "repetition-pressure-v1",
    "eligible": true,
    "triggered": true,
    "score": 0.72,
    "similarity_threshold": 0.46,
    "repeat_count": 2,
    "similar_count": 1,
    "min_repeats": 2,
    "window_seconds": 1800,
    "similar_event_ids": ["..."]
  }
}
```

Contract:

- Repetition pressure only amplifies user prompts that already meet the classifier review threshold.
- Repetition state is local and bounded under `feedback/repetition-state.json`; it stores hashed comparison features, not raw prompt text.
- Assistant messages, backfill, Codex file/context wrappers, control phrases, pasted context, and duplicate hook/scanner observations do not increment pressure.
- A repeated-pressure event queues through the same `trigger-queue.jsonl` and worker path as classifier-triggered events.

## Trigger Batch

```json
{
  "batch_id": "20260614T000000Z-project-session",
  "project_key": "~/Companion/Code/companion",
  "session_ids": ["..."],
  "canonical_event_ids": ["..."],
  "mode": "immediate|nightly|quiet|manual",
  "cooldown": {
    "global_remaining_seconds": 0,
    "session_remaining_seconds": 0
  },
  "state": "queued|running|staged|applied|no_change|failed|blocked"
}
```

Contract:

- Global cooldown should not hide which project/session owns the delayed work.
- Quiet/manual mode records events without spawning the reflector.
- A batch must declare whether it may mutate files.

## Evidence Bundle

```json
{
  "bundle_id": "...",
  "batch_id": "...",
  "trigger_events": ["..."],
  "transcript_context": {
    "path": "...",
    "turns_before": 4,
    "turns_after": 4,
    "summary": "..."
  },
  "agent_surfaces": [
    {
      "kind": "global_prompt|project_prompt|home_memory|skill|project_skill|hook",
      "path": "...",
      "scope": "global|project|home",
      "loaded_for_event": true
    }
  ],
  "closest_skills": [
    {
      "id": "react-doctor",
      "path": "...",
      "match_reason": "trigger mentions React state/hook structure"
    }
  ],
  "history": {
    "same_project_trigger_count": 0,
    "same_classification_count": 0,
    "recent_related_changes": []
  }
}
```

Contract:

- The bundle must be readable without the original model context.
- It must include enough evidence to reject a change, not just to justify one.

## Classifier Decision

```json
{
  "decision_id": "...",
  "batch_id": "...",
  "classification": "no_change|core_prompt|project_prompt|home_memory|skill_new|skill_update|project_skill_new|project_skill_update|skill_prune|hook_or_script",
  "confidence": 0.0,
  "diagnosis": "one-sentence behavioral failure or false-positive reason",
  "evidence": [
    "file:line or command-output reference"
  ],
  "rejected_alternatives": [
    {
      "classification": "core_prompt",
      "reason": "too project-specific"
    }
  ],
  "proposed_changes": [
    {
      "path": "...",
      "operation": "create|update|delete|stage",
      "summary": "..."
    }
  ],
  "verification_plan": [
    "Run scripts/validate-skills.py",
    "Probe near-miss prompt"
  ],
  "apply_mode": "none|stage|auto_apply"
}
```

Contract:

- `no_change` is a first-class success state.
- `confidence` below the configured threshold stages or records only.
- `hook_or_script` requires deterministic tests before apply.

## Staged Change

```json
{
  "proposal_id": "...",
  "decision_id": "...",
  "created_at": "...",
  "target_surface": "project_skill_update",
  "files": [
    {
      "path": "...",
      "diff_path": "...",
      "risk": "low|medium|high"
    }
  ],
  "status": "pending|approved|rejected|applied|superseded",
  "verification": {
    "commands": [],
    "status": "not_run|pass|fail|blocked",
    "untested": []
  }
}
```

Contract:

- Staged changes live under the private Introspect home or ignored feedback directory until approved.
- Applied changes write surface diffs for rollback.
- Project skill changes target the project by default, not the global skill library.
