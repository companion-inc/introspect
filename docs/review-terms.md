# Review Terms

Introspect wakes from the local intent classifier, not from a shipped word list.

The optional `~/.introspect/trigger-words.txt` file is only review metadata. It can tag events with exact lowercase terms when the user deliberately creates the file, but Introspect does not install defaults and does not need this file to wake the reflector.

The normal wake path is:

1. Score the prompt with `~/.introspect/models/wake-logreg-v2-round4.json`.
2. Queue the event when the score meets the production model threshold, currently `0.675`.
3. Keep scores from the review threshold, currently `0.30`, up to `0.675` as review-only telemetry.
4. Record optional review metadata when `trigger-words.txt` exists.
5. Use `INTROSPECT_TRIGGER_WORD_FALLBACK=1` only as an explicit emergency fallback.

Codex Desktop still has a scanner backstop because changed command hooks can be skipped until the hook definition is trusted or the app session reloads config. The scanner reads recent `~/.codex/sessions/**/rollout-*.jsonl` files, ignores Codex control/context records, dedupes transcript lines, and queues missed classifier-triggered prompts through the same single-worker cooldown path.
