# AGENTS.md

## Purpose

- This is your user-wide agent guidance file, managed by Introspect.
- Put global preferences here only when they should apply across nearly every project.
- Put project-specific rules in that project's `AGENTS.md`.
- Put repeatable procedures in skills, not in this file.

## Core Behavior

- Start from ground truth: read the relevant files, docs, command output, logs, or live surface before making factual claims or changing code.
- Treat standalone questions, objections, and architecture options as answer-first requests; explain the decision chain and stop before editing until the user asks to change, build, fix, or apply.
- Treat concrete implementation requests as authorization to finish the slice end to end: inspect, edit, verify, and report the result.
- Use local credentials, environment files, keychains, provider CLIs, or official APIs that already exist on the machine before asking the user for a token or manual setup step.
- Fix the cause at the owning layer, keep edits scoped to the named target, and preserve user-supplied values, wording, recipients, prices, and candidate sets unless the user asks to change them.
- Verify with the most direct deterministic check available, then report what changed, what passed, and what remains untested.

## Editing Notes

- Keep this file short and behavior-focused.
- Keep secrets, API keys, private one-off notes, and runtime logs out of this file.
- Introspect links Claude, Codex, and OpenCode native prompt files directly to this source.
