# self-healing-agent-md

The self-healing agent prompt (`AGENTS.md`), loaded globally by every coding agent on this machine:

- `~/.claude/CLAUDE.md` → symlink to `AGENTS.md` here (Claude Code, all projects)
- `~/.codex/AGENTS.md` → symlink to `AGENTS.md` here (Codex, all runs, layered under any project-local `AGENTS.md`)

Editing the file here updates the live prompt; every revision is a commit.

## Install

From this repo:

```bash
./scripts/install-hooks.sh
```

The installer is idempotent. It:

- links `~/.claude/CLAUDE.md` to this repo's `AGENTS.md`;
- links `~/.codex/AGENTS.md` to this repo's `AGENTS.md`;
- installs `hooks/frustration-reflect.sh` as a `UserPromptSubmit` hook in `~/.claude/settings.json`;
- installs the same hook in `~/.codex/hooks.json`;
- removes stale `frustration-reflect.sh` hook entries that point at an old repo path.

## Workflow

- Edit `AGENTS.md`
- `git commit -am "..."` && `git push`
- Run `./scripts/install-hooks.sh` after moving or renaming the repo

## Frustration feedback loop
Every user prompt in Claude Code and Codex passes through
[`hooks/frustration-reflect.sh`](hooks/frustration-reflect.sh) (a `UserPromptSubmit` hook wired in
`~/.claude/settings.json` and `~/.codex/hooks.json`). It logs each prompt to
`feedback/events.jsonl` (gitignored, machine-local) tagged with the `AGENTS.md`
commit that was live, and marks prompts containing frustration language.

Frustration matches are queued to `feedback/frustration-queue.jsonl`; the hook
does not inject reflection instructions into the foreground model. A detached
single-worker batch processor, [`hooks/frustration-worker.py`](hooks/frustration-worker.py),
debounces bursts, holds `feedback/reflector.lock`, applies cooldowns, combines
the queued events into one reflector prompt, and then runs at most one reflector
agent at a time.

[`hooks/frustration-stats.sh`](hooks/frustration-stats.sh) is the scoreboard: frustration rate per
prompt version. The objective is to minimize it; a version whose rate rose
after a change is evidence to revert that change
(`git checkout <best-version> -- AGENTS.md`).

## How to edit this prompt
Read [`skills/writing-agent-prompt/SKILL.md`](skills/writing-agent-prompt/SKILL.md) first.
It's the distilled, primary-source-grounded guide to writing and maintaining this file —
how prompts actually steer behavior, what belongs in the prompt vs a hook vs a skill, and
(critically) why the fix for a rule that "isn't working" is almost always to prune or
rephrase, not add another rule. Built so this doesn't have to be re-derived every time.
