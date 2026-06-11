# agents-md

The agent system prompt (`AGENTS.md`), loaded globally by every coding agent on this machine:

- `~/.claude/CLAUDE.md` → symlink to `AGENTS.md` here (Claude Code, all projects)
- `~/.codex/AGENTS.md` → symlink to `AGENTS.md` here (Codex, all runs, layered under any project-local `AGENTS.md`)

Editing the file here updates the live prompt; every revision is a commit.

## Workflow
- Edit `AGENTS.md`
- `git commit -am "..."` && `git push`

## How to edit this prompt
Read [`skills/writing-agents-md/SKILL.md`](skills/writing-agents-md/SKILL.md) first.
It's the distilled, primary-source-grounded guide to writing and maintaining this file —
how prompts actually steer behavior, what belongs in the prompt vs a hook vs a skill, and
(critically) why the fix for a rule that "isn't working" is almost always to prune or
rephrase, not add another rule. Built so this doesn't have to be re-derived every time.
