---
name: writing-agent-prompt
description: Write or revise model-facing prompt text so the desired behavior is stated as the output to produce, then verify it with real response probes. Use when editing AGENTS.md, CLAUDE.md, system prompts, prompt rules, or when prompt wording makes the agent explain, ask permission, or stall instead of acting.
---

# Writing Agent Prompt

## Purpose

Use this skill for prompt wording after `agent-md-creator` has decided that the behavior belongs in an always-loaded prompt. This skill is about phrasing and behavioral verification, not placement.

## Procedure

1. Read the failure transcript and name the unwanted model move in one sentence.
2. Write the desired first move and final artifact in plain behavioral terms.
3. Rewrite the instruction with action verbs such as `produce`, `implement`, `continue`, `substitute`, `verify`, and `report`.
4. Put research requirements inside the action path: the model should discover missing details with tools while moving toward the artifact.
5. If a sub-action cannot run, phrase the recovery as substitution and continuation.
6. Verify by probing the actual agent with a realistic prompt from the failure and reading the response for behavior. The response should start the work, name the first concrete action, and avoid asking for permission when authorization is already present.
7. If the probe fails, revise the prompt and probe again. Do not replace the behavioral test with a text-matching proxy.

## Gotchas

- A prompt can match expected words and still fail behaviorally. Judge the response, not isolated text.
- A text-matching proxy can block legitimate prompt text while missing the same failure expressed another way.
- Prefer "answer with the changed artifact and verification" over naming every bad response style.
- A hidden or empty skill folder is not a skill. It needs `SKILL.md` frontmatter and an index entry so the reflector can route to it.
- Do not blindly obey this skill when the edited prompt is for a regulated product workflow; read the product docs and verify the result against the real prompt file.

## Verification

- Run at least one behavior probe against the actual agent runtime that loads the edited prompt.
- Run `./scripts/validate-skills.py` after creating or changing this skill.
- For core prompt edits, run `./scripts/introspect-status.sh` and confirm Claude and Codex prompt links target the edited file.

## Sources

- Internal failure pattern: an IP/trademark preamble stopped the requested artifact instead of producing the safe transformed output.
- Repo: `skills/agent-md-creator/SKILL.md` says rephrase buried or ambiguous rules before adding prompt bloat.
- OpenAI Codex Skills docs: skills need `SKILL.md`, name, description, and clear trigger boundaries for implicit activation.
- Agent Skills specification: a skill directory must contain `SKILL.md` with `name` and `description` frontmatter.
- Anthropic prompt docs: current Claude prompting guidance favors clear, explicit, action-oriented instructions and tells prompt authors to prefer telling the model what to do.
