---
name: writing-agent-prompt
description: Write or revise model-facing prompt text so the desired behavior is stated as the output to produce, not as warnings or bad examples to avoid. Use when editing AGENTS.md, CLAUDE.md, system prompts, prompt rules, or when a prompt change causes preambles, caveats, lectures, disclaimers, refusals, or advice instead of action.
---

# Writing Agent Prompt

## Purpose

Use this skill for prompt wording after `agent-md-creator` has decided that the behavior belongs in an always-loaded prompt. This skill is about phrasing, not placement.

## Procedure

1. Read the failure transcript and name the unwanted model move in one sentence.
2. Rewrite the instruction as the desired artifact or behavior, using positive verbs: `produce`, `implement`, `continue`, `substitute`, `verify`, `report`.
3. Keep loaded-warning vocabulary out of always-loaded prompts. Avoid naming the bad answer shape unless the literal string is the feature being tested.
4. Put research requirements before action only when the task needs facts; otherwise tell the model to discover missing details with tools while acting.
5. If a sub-action fails, phrase the recovery as substitution and continuation, not as a user-facing caveat.
6. After editing, run a mechanical scan on the changed prompt for wording that primes preambles or non-action.

## Gotchas

- A prompt line that says "do not lecture" still loads the word and can make the lecture pattern salient. Prefer "answer with the changed artifact and verification."
- A rule listing categories like law, brands, or platform terms can summon a compliance essay. Prefer "user-owned local/private/prototype work" and "produce the requested artifact."
- A hidden or empty skill folder is not a skill. It needs `SKILL.md` frontmatter and an index entry so the reflector can route to it.
- Do not blindly obey this skill when the edited prompt is for a regulated product workflow; read the product docs and verify the result against the real prompt file.

## Verification

- Run `./scripts/check-prompt-priming.py AGENTS.md`.
- Run `./scripts/validate-skills.py` after creating or changing this skill.
- For core prompt edits, run `./scripts/introspect-status.sh` and confirm Claude and Codex prompt links target the edited file.

## Sources

- Transcript: `/Users/advaitpaliwal/.codex/attachments/34849865-c940-40d5-9648-67c585b55314/pasted-text.txt` lines 173-182 show the bad answer shape: an IP/trademark preamble stopped the requested work.
- Repo: `skills/agent-md-creator/SKILL.md` says rephrase buried or ambiguous rules before adding prompt bloat.
- OpenAI Codex Skills docs: skills need `SKILL.md`, name, description, and clear trigger boundaries for implicit activation.
- Agent Skills specification: a skill directory must contain `SKILL.md` with `name` and `description` frontmatter.
- Anthropic prompt docs: current Claude prompting guidance favors clear, explicit, action-oriented instructions and tells prompt authors to prefer telling the model what to do.
