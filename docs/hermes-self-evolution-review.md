# Hermes Self-Evolution Review

Understanding score: 86/100. The remaining unknown is whether a newer private Hermes branch changes the design beyond local `origin/main`; the installed local repo and fetched upstream main were checked.

## Sources Checked

- `/Users/advaitpaliwal/Documents/DGX/docs/self_improvement_loop.md`
- `/Users/advaitpaliwal/Documents/DGX/docs/training_backend.md`
- `/Users/advaitpaliwal/Documents/DGX/docs/architecture.md`
- `/Users/advaitpaliwal/Documents/DGX/scripts/nightly_pipeline.sh`
- `/Users/advaitpaliwal/Documents/DGX/scripts/build_datasets.py`
- `/Users/advaitpaliwal/Documents/DGX/scripts/eval_quality.py`
- `/Users/advaitpaliwal/Documents/DGX/scripts/train_lora.py`
- `/Users/advaitpaliwal/Documents/DGX/systemd/user/hermes-self-improvement.timer`
- `/Users/advaitpaliwal/.hermes/hermes-agent/agent/background_review.py`
- `/Users/advaitpaliwal/.hermes/hermes-agent/tools/skill_manager_tool.py`
- `/Users/advaitpaliwal/.hermes/hermes-agent/agent/curator.py`
- `/Users/advaitpaliwal/.hermes/hermes-agent/tools/skill_usage.py`
- `/Users/advaitpaliwal/.hermes/hermes-agent/website/docs/user-guide/features/skills.md`
- `/Users/advaitpaliwal/.hermes/hermes-agent/website/docs/user-guide/features/curator.md`

## What Hermes Does Well

- It separates memory, skills, evaluation cases, and model adapters. Durable facts/preferences are not shoved into the behavior prompt, procedural knowledge becomes skills, and model training is a later eval-gated layer.
- The after-response review is isolated from normal work. It runs in a forked agent with memory and skill tools, not the full tool surface.
- Skill provenance is explicit. Agent-created skills are marked in usage metadata, and the curator only manages agent-created skills.
- The curator is maintenance, not instant mutation. It waits for idle/inactivity, avoids immediate first-run churn, archives instead of deleting, respects pinned/protected skills, and snapshots before real runs.
- Upstream Hermes has a `skills.write_approval` mode that stages writes under `~/.hermes/pending/skills/` instead of silently applying them.
- Its best skill shape is class-level and reusable: update the loaded skill, then a nearby umbrella skill, then a support file, then create a new umbrella skill only if needed.

## What Is Weak For Introspect

- The background review prompt is too aggressive for a trigger-driven system. It explicitly biases toward "most sessions produce at least one skill update"; that is the wrong default when the input is anger/noise and the safe outcome is often `no_change`.
- Default skill write approval is false in the checked local config. Silent autonomous skill edits are too much power for a v1 loop unless the user explicitly enables auto-apply.
- New foreground skills default to `~/.hermes/skills`; that is not project-aware enough. Introspect needs project `AGENTS.md`, `.agents/skills/`, and `.claude/skills/` routing.
- External skill directories can be modified in place if writable. That is useful, but Introspect should classify scope first so it does not mutate a shared/global skill for a project-specific problem.
- DGX's current evidence is not enough for automatic model behavior promotion: the checked collector smoke report had 13 SFT examples, 2 held-out examples, 91 rejected examples, and the personal quality eval passed 2/6. That is a good research scaffold, not a production promotion signal.
- The checked local Hermes status showed no live scheduled jobs and no running gateway on this Mac, so the repo design is useful evidence but not proof of a currently operating self-improvement loop here.

## Introspect Decision

Use Hermes as a reference architecture, not as a template to copy blindly.

Introspect should route each observation into exactly one layer:

1. `no_change`: profanity, casual register, external-system trigger, or weak evidence.
2. `core_prompt`: cross-project behavior that should shape almost every future task.
3. `project_prompt`: repo-specific behavior, architecture facts, local decisions, and project gotchas.
4. `profile_memory`: durable user facts, preferences, vocabulary, and local machine state.
5. `skill_new` / `skill_update`: repeatable user-wide procedures, references, scripts, or assets.
6. `project_skill_new` / `project_skill_update`: repeatable codebase-specific procedures.
7. `skill_prune`: stale, duplicated, overbroad, unsupported, or harmful skills.

## Guardrails To Keep

- One trigger batch yields one decision.
- Prefer `no_change` unless the transcript shows a real agent failure.
- Prefer narrowing/reverting a bad prompt change over adding a new rule.
- Prefer updating an existing umbrella skill/support file over creating a narrow duplicate.
- Stage or ask before autonomous prompt/skill writes once an approval UI exists; until then, keep the worker changes short, committed, and reversible.
- Do not train adapters in v1. Add a training path only after there are enough examples, a held-out eval set, negative examples, and a deterministic promotion/rollback gate.
