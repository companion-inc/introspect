---
name: skill-creator
description: Create, update, prune, and validate agent-loop skills as scoped procedural memory instead of bloating AGENTS.md. Use for reflector decisions involving skill_new, skill_update, skill_prune, reusable workflows from observed failures, or placement decisions between a skill and the global prompt.
---

# Skill creator

## Core rule

A skill is not a second global prompt. It is scoped procedural memory: a compact, source-backed workflow that loads only when the task needs it.

Create or update a skill only when the lesson is reusable for a class of future tasks and too specific for always-loaded AGENTS.md. Prune a skill when evidence shows it is stale, overbroad, duplicative, or causing bad behavior. If the lesson must apply across nearly every task, edit AGENTS.md instead. If it is one-off anger, casual profanity, or trigger about an external system, make no change.

## Source gate

Before writing a new skill or materially changing one:

1. Read the failure transcript/event that triggered the change.
2. Read `skills/index.json` and the closest existing `skills/*/SKILL.md`; update instead of duplicating when there is a close fit.
3. Read `references/source-map.md` in this skill, then open the primary sources relevant to the change.
4. Read the primary source for the skill format or behavior being encoded:
   - Agent Skills specification: https://agentskills.io/specification
   - OpenAI Codex Skills docs: https://developers.openai.com/codex/skills
   - OpenAI API Skills docs: https://developers.openai.com/api/docs/guides/tools-skills
   - Claude Agent Skills overview: https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview
   - Anthropic public skills repository: https://github.com/anthropics/skills
   - Anthropic skill-creator reference: https://github.com/anthropics/skills/blob/main/skills/skill-creator/SKILL.md
   - Agent Skills best practices: https://agentskills.io/skill-creation/best-practices
   - Agent Skills description optimization: https://agentskills.io/skill-creation/optimizing-descriptions
   - Agent Skills eval guidance: https://agentskills.io/skill-creation/evaluating-skills
5. For self-evolving skill curation, read the research source that matches the operation:
   - SAGE / skill library agents: https://arxiv.org/html/2512.17102v2
   - SkillOS / skill curation: https://arxiv.org/html/2605.06614v1
   - SkillRL / recursive skill evolution: https://github.com/aiming-lab/SkillRL
6. For domain behavior inside the skill, cite actual domain sources: repo files, docs, logs, APIs, papers, issues, or command output. Do not encode generic model folklore as a rule.
7. If no source supports the lesson, write nothing and log why.

## Shape

Each skill lives at `skills/<slug>/SKILL.md` and has YAML frontmatter:

```yaml
---
name: lower-case-hyphen-slug
description: What this skill does, when it should load, and the boundary against near-misses.
---
```

Keep the body short and operational:

- What problem this skill handles.
- Activation boundary: concrete signals and near-misses.
- Procedure: the steps that prevent the observed failure.
- Gotchas: non-obvious facts the agent would otherwise miss.
- Verification: how to prove the skill worked.
- Sources: URLs, repo paths, file:line evidence, commands, or transcripts used.

Do not create README, changelog, install guide, or meta-doc files inside a skill. Put reference material under `references/` only when the main `SKILL.md` would become bulky, and link to the exact reference file with when to read it.

## Decision Rules

- `skill_new`: use only when there is no close existing skill and the lesson is a reusable workflow, domain, tool integration, or repeated failure shape.
- `skill_update`: use when a close existing skill exists but missed a boundary, gotcha, source, or validation step.
- `skill_prune`: use when an existing skill is stale, duplicated, overbroad, unsupported by sources, or harmful. Prefer marking `status: deprecated` and narrowing activation signals before deleting files.
- `core_prompt`: use when the rule is always-on across most tasks, not a scoped workflow.
- `no_change`: use for false positives, external venting, casual register, or unsupported guesses.

## Writing Rules

- Prefer source-backed procedures over declarations. "Run X, check Y, then Z" beats "be careful."
- Include only information the agent would plausibly get wrong without the skill.
- Give a default path. Mention alternatives only when the agent needs a decision rule for choosing them.
- Avoid banned trigger-language placeholders. Use `activation_signals` in `skills/index.json`.
- Keep names short, lowercase, and verb/domain clear. The folder name and frontmatter `name` must match.
- Add or update the `skills/index.json` entry with `id`, `path`, `status`, `tier`, `description`, and `activation_signals`.
- Keep the index compact: active skills should have crisp boundaries; deprecated skills stay in the index only long enough to explain the transition.

## Validation

After any skill change:

1. Run:

```bash
INTROSPECT_SKILLS_DIR="$PWD/skills" ./scripts/validate-skills.py
```

2. Read the changed skill as a fresh agent would: can it act from the skill alone, without hidden context?
3. For risky or broad skills, create at least one positive and one near-miss negative trigger example in the reflector log or commit notes.
4. Commit one lesson per commit with a behavioral message.

## Why This Design

- The Agent Skills standard defines a skill as a folder with required `SKILL.md`, required `name` and `description`, optional scripts/references/assets, and progressive disclosure.
- OpenAI Codex Skills load name, description, and path first; full instructions load only after Codex decides to use the skill, so descriptions carry the trigger burden.
- Claude Agent Skills use the same progressive disclosure pattern: metadata first, `SKILL.md` after trigger, optional resources only when needed.
- Agent Skills best practices say effective skills should come from real expertise, real executions, project artifacts, corrections, and failure cases, not generic prompt generation.
- SAGE, SkillOS, and SkillRL support the same architectural direction: reusable skills distilled from experience improve later related tasks, and skill curators should insert, update, prune, and keep the library compact based on downstream feedback.
