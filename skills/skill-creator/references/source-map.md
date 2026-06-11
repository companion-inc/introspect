# Skill-Creator Source Map

Use this file before changing `skills/skill-creator/SKILL.md` or before a reflector creates, updates, or prunes another skill. It maps primary sources to concrete repo rules.

## Format Sources

### Agent Skills specification

Source: https://agentskills.io/specification

Relevant facts:
- A skill is a directory with required `SKILL.md` and optional `scripts/`, `references/`, and `assets/`.
- `SKILL.md` must contain YAML frontmatter followed by Markdown.
- Required frontmatter: `name` and `description`.
- `name` is lowercase alphanumeric plus hyphens, max 64 characters, and should match the parent directory.
- `description` is max 1024 characters and should describe both what the skill does and the trigger boundary.
- Progressive disclosure: metadata loads first, full `SKILL.md` loads after activation, resources load only as needed.

Repo consequences:
- `skills/<id>/SKILL.md` is the canonical unit.
- `skills/index.json` must use lowercase hyphen IDs matching frontmatter `name`.
- Keep `SKILL.md` under control; push bulky details to one-hop `references/` files.
- The description and `activation_signals` carry the retrieval boundary, so near-miss cases belong there.

### OpenAI Codex Skills

Source: https://developers.openai.com/codex/skills

Relevant facts:
- Codex starts with name, description, and file path; full instructions load only after it decides to use the skill.
- Implicit activation depends on the skill description.
- Skills can include optional scripts, references, assets, and agents metadata.

Repo consequences:
- The reflector must not create vague skills whose description cannot route them.
- A skill should be instruction-only by default; add scripts only for repeated deterministic operations.
- The index should stay small enough that keyword-first routing remains reliable.

### OpenAI API Skills

Source: https://developers.openai.com/api/docs/guides/tools-skills

Relevant facts:
- A skill is a versioned bundle of files plus a `SKILL.md` manifest.
- Skills codify processes and conventions, from style guides to multi-step workflows.

Repo consequences:
- Each skill change is a versioned behavior change and should be committed separately.
- Use skills for repeatable workflows and conventions, not one-off reactions.

### Claude Agent Skills overview

Source: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview

Relevant facts:
- Skills use progressive disclosure: metadata at startup, `SKILL.md` when triggered, extra files as needed.
- Claude Code custom skills are filesystem-based and discovered automatically in supported locations.
- Scripts can run without loading the whole script body into the context window.

Repo consequences:
- Keep operational code in scripts when deterministic execution matters.
- Keep source references separate so the reflector can load them only when needed.
- Do not make AGENTS.md carry every scoped workflow.

### Anthropic public skills repository and skill-creator

Sources:
- https://github.com/anthropics/skills
- https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md

Relevant facts:
- Anthropic's public repo treats each skill as a self-contained folder with `SKILL.md`.
- The public `skill-creator` focuses on creating, modifying, improving, evaluating, benchmarking, and optimizing skills.
- The high-level loop is draft, test prompts, evaluate qualitatively and quantitatively, rewrite, repeat, then expand test coverage.

Repo consequences:
- This repo's internal skill should be called `skill-creator`, not a vague writing name.
- The reflector should create testable skill changes and avoid shipping skill edits with no validation.
- For broad skills, add positive and near-miss negative examples in logs or commit notes.

### Agent Skills best practices

Source: https://agentskills.io/skill-creation/best-practices

Relevant facts:
- Effective skills come from real expertise, real executions, corrections, project artifacts, issue trackers, code review, version history, and failure resolutions.
- Skills should include what the agent lacks and omit what it already knows.
- Skills should be coherent units, not too narrow and not too broad.
- Moderate detail with progressive disclosure beats exhaustive always-loaded instructions.
- Gotchas, checklists, templates, validation loops, and bundled scripts are useful patterns.

Repo consequences:
- Every skill addition must trace to a real observed failure or concrete source.
- The core body should encode procedure and gotchas, not generic advice.
- Add scripts only when the agent would otherwise rewrite the same fragile logic.

### Agent Skills description optimization

Source: https://agentskills.io/skill-creation/optimizing-descriptions

Relevant facts:
- The description is the primary mechanism agents use to decide whether to load a skill.
- Trigger tests need realistic positive prompts and near-miss negative prompts.
- Description iteration should avoid overfitting to exact failed queries.

Repo consequences:
- `activation_signals` should include intent-level signals, not only exact words from one frustration message.
- Near-miss negatives belong in the skill body or reflector log for broad changes.
- If routing becomes noisy, improve descriptions before adding embedding retrieval.

### Agent Skills eval guidance

Source: https://agentskills.io/skill-creation/evaluating-skills

Relevant facts:
- Skill quality should be tested on realistic prompts, varied phrasing, edge cases, and file/context details.
- Compare with-skill against without-skill or previous-skill baselines.
- Assertions should be evidence-backed and mechanically checked when possible.

Repo consequences:
- For broad or risky skill changes, a dry-run is not enough; test the intended behavior and at least one near miss.
- Mechanical checks belong in scripts where possible.
- Log what was not checked.

## Self-Evolving Agent Sources

### SAGE: Reinforcement Learning for Self-Improving Agent with Skill Library

Source: https://arxiv.org/html/2512.17102v2

Relevant facts:
- Skill-library agents can use skills, generate skills, update failed skills, and save successful new or updated skills.
- SAGE accumulates skills across related task chains and makes previous skills available to later tasks.
- Reported results show higher goal completion with fewer steps and fewer tokens when skill usage is learned well.

Repo consequences:
- The feedback loop should not dump every lesson into AGENTS.md; reusable lessons should accumulate in skills.
- A skill that fails should be updated, not duplicated.
- Save a skill only after it is valid and plausibly reusable.

### SkillOS: Learning Skill Curation for Self-Evolving Agents

Source: https://arxiv.org/html/2605.06614v1

Relevant facts:
- SkillOS separates a frozen executor from a skill curator that updates an external SkillRepo.
- The curator performs insert, update, and delete operations based on accumulated experience.
- Skills are represented as Markdown files with YAML frontmatter and Markdown body.
- Skill quality, valid operations, downstream task outcomes, and compactness are all reward signals.

Repo consequences:
- This repo should treat the reflector as a curator and normal Claude/Codex as executors.
- The curator needs `skill_new`, `skill_update`, and `skill_prune`; create-only growth will bloat the library.
- Compactness is a real objective, so pruning and narrowing are first-class operations.

### SkillRL

Source: https://github.com/aiming-lab/SkillRL

Relevant facts:
- SkillRL distills successful trajectories into strategic patterns and failed trajectories into concise lessons.
- It distinguishes broad general skills from task-specific skills.
- It supports recursive skill evolution and retrieval by template or embeddings.

Repo consequences:
- Keep always-on rules in AGENTS.md, core-maintenance procedures in core skills, and domain workflows in domain skills.
- Start with keyword-first routing and upgrade retrieval only when the index becomes noisy.
- Failure lessons should be concise and action-guiding, not raw transcript summaries.

## Placement Matrix

Use this matrix after reading the failure transcript:

| Evidence | Operation |
| --- | --- |
| False positive, external venting, no actionable agent behavior | `no_change` |
| Always-on invariant across most tasks | `core_prompt` |
| Reusable scoped workflow with no close existing skill | `skill_new` |
| Existing skill close but missing a boundary, gotcha, source, or validation step | `skill_update` |
| Existing skill stale, duplicated, overbroad, unsupported, or harmful | `skill_prune` |
| Must happen deterministically every time | hook or script, not prompt text |

## Source Standard

Every skill change must name at least one source class:

- Transcript/event: the observed failure or success.
- Repo source: files, logs, tests, commits, issues, or docs.
- Product docs: official docs for the API/tool/format.
- Research source: paper or reference implementation for curation behavior.
- Validation evidence: command output, dry-run prompt, eval result, or real flow.

No source means no change.
