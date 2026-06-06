# agent-system-prompt

Agent system prompt, loaded as `~/.codex/AGENTS.md` (Codex home scope —
applies to every Codex run in every repo, layered under any project-local `AGENTS.md`).

`~/.codex/AGENTS.md` is a symlink to `AGENTS.md` in this repo, so editing the file
here updates the live prompt, and every revision is captured as a commit.

## Workflow
- Edit `AGENTS.md`
- `git commit -am "..."` && `git push`

## How to edit this prompt
Read [`skills/writing-agent-prompts/SKILL.md`](skills/writing-agent-prompts/SKILL.md) first.
It's the distilled, primary-source-grounded guide to writing and maintaining this file —
how prompts actually steer behavior, what belongs in the prompt vs a hook vs a skill, and
(critically) why the fix for a rule that "isn't working" is almost always to prune or
rephrase, not add another rule. Built so this doesn't have to be re-derived every time.
