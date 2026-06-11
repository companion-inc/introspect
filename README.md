# self-healing-agent-md

Global `AGENTS.md` prompt management plus a frustration-feedback hook loop for Claude Code and Codex.

This repo keeps one machine-wide agent prompt under version control, installs it into both Claude and Codex, logs user frustration signals, and runs a single background reflector that can improve the right layer when the evidence supports a change: the always-loaded prompt for universal rules, or a scoped skill for domain/workflow lessons.

## What It Installs

- `~/.claude/CLAUDE.md` -> this repo's `AGENTS.md`
- `~/.codex/AGENTS.md` -> this repo's `AGENTS.md`
- `~/.claude/settings.json` `UserPromptSubmit` hook -> `hooks/frustration-reflect.sh`
- `~/.codex/hooks.json` `UserPromptSubmit` hook -> `hooks/frustration-reflect.sh`

The installer is idempotent. It backs up files it replaces and removes stale `frustration-reflect.sh` hook entries before adding the current one.

## Requirements

- `bash`
- `python3`
- `git`
- Claude Code and/or Codex using their local hook config files
- `claude` on `PATH` for real background reflection runs

## Install

Clone or move the repo to the expected path:

```bash
mkdir -p ~/Projects
git clone https://github.com/advaitpaliwal/self-healing-agent-md.git ~/Projects/self-healing-agent-md
cd ~/Projects/self-healing-agent-md
```

Install the prompt links and both hooks:

```bash
./scripts/install-hooks.sh
```

If this repo is already cloned somewhere else, run the installer from that checkout. The hook paths will point at the checkout you run it from.

## Verify

Check the prompt links:

```bash
readlink ~/.claude/CLAUDE.md
readlink ~/.codex/AGENTS.md
```

Both should print:

```text
/Users/advaitpaliwal/Projects/self-healing-agent-md/AGENTS.md
```

Check the hook commands:

```bash
python3 - <<'PY'
import json
from pathlib import Path

expected = "/Users/advaitpaliwal/Projects/self-healing-agent-md/hooks/frustration-reflect.sh"
for path in ["~/.claude/settings.json", "~/.codex/hooks.json"]:
    data = json.loads(Path(path).expanduser().read_text())
    commands = [
        hook.get("command")
        for group in data["hooks"]["UserPromptSubmit"]
        for hook in group.get("hooks", [])
    ]
    print(path, commands)
    assert commands.count(expected) == 1
PY
```

Run a dry-run hook test:

```bash
tmp_feedback="$(mktemp -d)"
AGENTS_MD_FEEDBACK_DIR="$tmp_feedback" \
FRUSTRATION_REFLECTOR_DRY_RUN=1 \
FRUSTRATION_DISABLE_SCHEDULE=1 \
FRUSTRATION_DEBOUNCE_SECONDS=0.1 \
./hooks/frustration-reflect.sh <<'JSON'
{"prompt":"WHAT THE FUCK WHY NOT","session_id":"readme-test","cwd":"/tmp","transcript_path":"/tmp/readme-test.jsonl"}
JSON
sleep 0.5
cat "$tmp_feedback/reflector-batches.jsonl"
rm -rf "$tmp_feedback"
```

The batch should show one dry-run event.

## Daily Workflow

Edit the live prompt:

```bash
$EDITOR AGENTS.md
git diff -- AGENTS.md
git commit -am "Describe the behavior change"
git push
```

Check the feedback scoreboard:

```bash
./hooks/frustration-stats.sh
```

After moving or renaming the checkout, rerun:

```bash
./scripts/install-hooks.sh
```

## How The Feedback Loop Works

1. Claude Code or Codex submits a user prompt.
2. `hooks/frustration-reflect.sh` logs the prompt metadata to `feedback/events.jsonl`.
3. If the prompt matches broad frustration language, the hook appends it to `feedback/frustration-queue.jsonl`.
4. `hooks/frustration-worker.py` debounces bursts, holds `feedback/reflector.lock`, applies global and per-session cooldowns, and runs at most one reflector process at a time.
5. The reflector inspects the transcript and stats. It either leaves the prompt unchanged or commits one small `AGENTS.md` improvement.

The foreground agent does not receive injected reflection instructions from the hook.

## Prompt Kernel And Skills

`AGENTS.md` is the kernel: it should contain only always-loaded invariants that are broadly useful across tasks. Scoped behavior belongs in `skills/`, where it can be loaded only for matching situations instead of bloating the global prompt.

Skill routing is tracked in `skills/index.json`. Each entry has:

- `id`: stable skill identifier.
- `path`: `SKILL.md` path.
- `status`: `candidate`, `active`, or `deprecated`.
- `activation_signals`: keyword-style signals used by humans or future retrieval code.
- `description`: one-sentence purpose.

Validate the skill library after edits:

```bash
./scripts/validate-skills.py
```

The current rule is simple: keyword-first routing, at most four loaded skills, and no embedding retrieval until keyword routing becomes noisy. This follows the practical shape of the best reference systems without importing their heavy RL training stack.

The reflector now chooses exactly one target for each batch:

- `no_change`: profanity was casual, external, or not actionable.
- `core_prompt`: a universal invariant belongs in `AGENTS.md`.
- `skill_new`: a scoped lesson deserves a new `skills/<slug>/SKILL.md`.
- `skill_update`: an existing skill should absorb the lesson.

## Configuration

Environment variables:

- `AGENTS_MD_REPO`: repo path override. Defaults to `~/Projects/self-healing-agent-md`.
- `AGENTS_MD_FEEDBACK_DIR`: feedback data directory. Defaults to `$AGENTS_MD_REPO/feedback`.
- `FRUSTRATION_DEBOUNCE_SECONDS`: burst debounce before a worker drains the queue. Defaults to `75`.
- `FRUSTRATION_COOLDOWN_SECONDS`: global cooldown between reflector runs. Defaults to `300`.
- `FRUSTRATION_SESSION_COOLDOWN_SECONDS`: per-session cooldown. Defaults to `900`.
- `FRUSTRATION_REFLECTOR_DRY_RUN=1`: write batches without invoking `claude -p`.
- `FRUSTRATION_DISABLE_SCHEDULE=1`: disable scheduled retry processes.

## Files

- `AGENTS.md`: global prompt loaded by Claude and Codex.
- `scripts/install-hooks.sh`: installer and uninstaller for prompt links and hooks.
- `hooks/frustration-reflect.sh`: `UserPromptSubmit` hook entrypoint.
- `hooks/frustration-worker.py`: locked background batch worker and change-target router.
- `hooks/frustration-stats.sh`: prompt-version frustration scoreboard.
- `hooks/launch-reflector.sh`: compatibility wrapper for manually queueing a reflection event.
- `skills/index.json`: skill routing index.
- `skills/writing-agent-prompt/SKILL.md`: guide for editing `AGENTS.md` without bloating it.
- `skills/high-stakes-forecasting/SKILL.md`: decision-support workflow for trades, forecasts, and consequential choices.
- `scripts/validate-skills.py`: local skill index and skill-file validator.
- `feedback/`: gitignored local logs, queues, locks, state, and reflector prompts.

## Troubleshooting

If hooks still point at the old path, rerun:

```bash
./scripts/install-hooks.sh
```

If no prompts are being logged, verify both settings files contain the hook command:

```bash
rg "frustration-reflect.sh" ~/.claude/settings.json ~/.codex/hooks.json
```

If a worker looks stuck, inspect:

```bash
tail -80 feedback/reflector.log
cat feedback/reflector-state.json
ps -ax -o pid,stat,etime,command | rg "frustration-worker.py|claude -p|sleep [0-9]+;"
```

If a config file is malformed JSON, restore the backup created by the installer. Backup files are written next to the original with a `.bak.<timestamp>` suffix.

## Privacy

Prompt metadata, frustration snippets, worker logs, queues, and reflector prompts are written under `feedback/`. That directory is gitignored and intended to stay machine-local.

## Uninstall

Remove this repo's prompt links and frustration hooks:

```bash
./scripts/install-hooks.sh --uninstall
```

The uninstaller only removes symlinks that point at this checkout's `AGENTS.md` and hook entries whose command ends with `/hooks/frustration-reflect.sh`.

## Help

Use the troubleshooting commands above first. If the repo behavior is wrong, open an issue on [GitHub](https://github.com/advaitpaliwal/self-healing-agent-md/issues) with the relevant command output and redacted `feedback/reflector.log` lines.

## License

No license file has been committed yet.

## Maintainer

Maintained by Advait Paliwal for this machine's Claude Code and Codex setup.

## References

- GitHub Docs, [About READMEs](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes)
- [SkillX](https://github.com/zjunlp/SkillX): best practical reference for turning trajectories into a structured skill library.
- [SkillRL](https://github.com/aiming-lab/SkillRL): useful reference for keyword-first vs embedding skill retrieval and dynamic updates.
- [MS-Agent Skill Module](https://github.com/modelscope/ms-agent/blob/main/ms_agent/skill/README.md): useful reference for `SKILL.md` packaging and progressive loading.
- [SAGE](https://github.com/amazon-science/SAGE): research reference for skill-augmented self-improvement, too heavy for this local hook loop.
