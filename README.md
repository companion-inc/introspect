# agent-profile

Private agent profile for this machine.

This repo contains the real always-loaded `AGENTS.md`, the private skill library, and ignored local feedback logs. It is intentionally private. The public hook framework lives in `advaitpaliwal/agent-loop`.

## Files

- `AGENTS.md`: live prompt symlinked into Claude Code and Codex.
- `skills/index.json`: routing index for scoped skills.
- `skills/*/SKILL.md`: private skill files.
- `feedback/`: ignored local queue, stats, and reflector logs.

## Installed Runtime

The public framework is installed from:

```text
/Users/advaitpaliwal/Projects/agent-loop
```

The live prompt links point here:

```text
~/.claude/CLAUDE.md -> /Users/advaitpaliwal/Projects/agent-profile/AGENTS.md
~/.codex/AGENTS.md -> /Users/advaitpaliwal/Projects/agent-profile/AGENTS.md
```

The Claude/Codex hook command uses the public framework while writing feedback to this private profile.

## Validate

Run the public validator against this private skill directory:

```bash
AGENTS_MD_SKILLS_DIR=/Users/advaitpaliwal/Projects/agent-profile/skills \
  /Users/advaitpaliwal/Projects/agent-loop/scripts/validate-skills.py
```

## Reinstall Hooks

```bash
/Users/advaitpaliwal/Projects/agent-loop/scripts/install-hooks.sh \
  --profile-repo /Users/advaitpaliwal/Projects/agent-profile \
  --prompt /Users/advaitpaliwal/Projects/agent-profile/AGENTS.md \
  --skills /Users/advaitpaliwal/Projects/agent-profile/skills
```
