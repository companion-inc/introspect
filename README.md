# agents-md

The agent system prompt (`AGENTS.md`), loaded globally by every coding agent on this machine:

- `~/.claude/CLAUDE.md` → symlink to `AGENTS.md` here (Claude Code, all projects)
- `~/.codex/AGENTS.md` → symlink to `AGENTS.md` here (Codex, all runs, layered under any project-local `AGENTS.md`)

Editing the file here updates the live prompt; every revision is a commit.

## Workflow
- Edit `AGENTS.md`
- `git commit -am "..."` && `git push`

## Frustration feedback loop
Every user prompt in Claude Code and Codex passes through
[`hooks/frustration-reflect.sh`](hooks/frustration-reflect.sh) (a `UserPromptSubmit` hook wired in
`~/.claude/settings.json` and `~/.codex/hooks.json`). It logs each prompt to
`feedback/events.jsonl` (gitignored, machine-local) tagged with the `AGENTS.md`
commit that was live, and marks prompts containing frustration language. On a
frustrated prompt it also injects an instruction telling the agent to
root-cause the trigger and evolve — or revert — `AGENTS.md` per the skill.

[`hooks/frustration-stats.sh`](hooks/frustration-stats.sh) is the scoreboard: frustration rate per
prompt version. The objective is to minimize it; a version whose rate rose
after a change is evidence to revert that change
(`git checkout <best-version> -- AGENTS.md`).

## How to edit this prompt
Read [`skills/writing-agents-md/SKILL.md`](skills/writing-agents-md/SKILL.md) first.
It's the distilled, primary-source-grounded guide to writing and maintaining this file —
how prompts actually steer behavior, what belongs in the prompt vs a hook vs a skill, and
(critically) why the fix for a rule that "isn't working" is almost always to prune or
rephrase, not add another rule. Built so this doesn't have to be re-derived every time.
