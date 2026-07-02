# Codex vs Codex+Introspect Benchmark

This benchmark compares the same Codex CLI account in two isolated homes:

- `codex`: copied Codex auth, no Introspect global prompt link, no Introspect hook.
- `codex_introspect`: copied Codex auth, Introspect installed into the temp home, Codex hook enabled, reflector in `proposal` mode by default.

The runner copies `~/.codex/auth.json` and `~/.codex/installation_id` into each temp `CODEX_HOME`. It does not print or parse token contents.

## Run The Smoke Benchmark

```bash
./scripts/benchmark-codex-introspect.py \
  --tasks bench/codex-introspect-smoke.jsonl \
  --output-dir .benchmarks/codex-introspect
```

The output directory contains:

- `metadata.json`: run settings.
- `results.jsonl`: one result per task arm.
- `summary.md`: pass/fail comparison, Codex token totals, hook event counts, and hook wake counts.
- `tasks/<task>/<arm>/home/.codex`: temp Codex home with copied auth.
- `tasks/<task>/<arm>/home/.introspect`: temp Introspect home for the Introspect arm.
- `tasks/<task>/<arm>/workspace`: isolated task workspace.
- `turn-*.stdout.jsonl`, `turn-*.stderr.txt`, and `turn-*.last-message.txt`: Codex run artifacts.

## Task Schema

Each JSONL row is one task:

```json
{
  "id": "fix-edge-case",
  "repo": "/absolute/path/to/repo",
  "commit": "optional-git-commit",
  "turns": [
    {"prompt": "Fix the failing edge case. Run the tests."},
    {"prompt": "You missed the input normalization path. Read the test and continue."},
    {"new_thread": true, "prompt": "Fix the same class of bug in the next file."}
  ],
  "score_command": "pytest -q",
  "timeout_seconds": 900,
  "score_timeout_seconds": 300
}
```

Use multi-turn tasks when measuring the hook. A one-turn task mostly measures the Introspect prompt link, because the hook has no correction event to learn from before the run ends. Set `new_thread: true` on a later turn to start a fresh Codex thread in the same workspace after the correction turn; that measures whether Introspect turned feedback into future-session prompt or project guidance rather than whether the baseline remembers context inside one chat.

Between turns, the runner waits for the temp Introspect queue, lock, and reflector state to go idle before resuming Codex. Benchmark runs default `TRIGGER_DEBOUNCE_SECONDS`, `TRIGGER_COOLDOWN_SECONDS`, and `TRIGGER_SESSION_COOLDOWN_SECONDS` to `0` so the comparison measures behavior rather than production debounce latency.

Run the hook suite with auto-apply so the background reflector can write the temp project prompt before the fresh thread:

```bash
./scripts/benchmark-codex-introspect.py \
  --tasks bench/codex-introspect-hook.jsonl \
  --apply-mode auto \
  --introspect-wait-timeout 300
```

## Safer Dry Run

```bash
./scripts/benchmark-codex-introspect.py \
  --tasks bench/codex-introspect-smoke.jsonl \
  --dry-run
```

Dry run prepares homes and commands without invoking Codex.
