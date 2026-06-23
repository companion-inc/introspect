# Review Terms

Introspect wakes from the local intent classifier, not from a shipped word list.

The optional `~/.introspect/trigger-words.txt` file is only review metadata. It can tag events with exact lowercase terms when the user deliberately creates the file, but Introspect does not install defaults and does not need this file to wake the reflector.

The normal wake path is:

1. Score the prompt with `~/.introspect/models/wake-logreg-v2-round4.json`.
2. Compute the effective wake threshold from the installed sensitivity setting. The bundled model threshold is `0.64`; the live `sensitive` setting maps to `0.40`.
3. Queue the event when the score meets the effective wake threshold.
4. Keep scores from the review threshold, currently `0.30`, up to the effective wake threshold as review-only telemetry.
5. Record optional review metadata when `trigger-words.txt` exists.

Codex Desktop still has a scanner backstop because changed command hooks can be skipped until the hook definition is trusted or the app session reloads config. The scanner reads recent `~/.codex/sessions/**/rollout-*.jsonl` files, ignores Codex control/context records, dedupes transcript lines, and queues missed classifier-triggered prompts through the same single-worker cooldown path.
