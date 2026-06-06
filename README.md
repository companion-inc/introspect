# codex-system-prompt

Global system prompt for Codex, loaded as `~/.codex/AGENTS.md` (Codex home scope —
applies to every Codex run in every repo, layered under any project-local `AGENTS.md`).

`~/.codex/AGENTS.md` is a symlink to `AGENTS.md` in this repo, so editing the file
here updates the live prompt, and every revision is captured as a commit.

## Workflow
- Edit `AGENTS.md`
- `git commit -am "..."` && `git push`
