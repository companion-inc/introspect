#!/usr/bin/env python3
# Trigger scoreboard: prompts, triggers, and rate per AGENTS.md version
# (commit), from feedback/events.jsonl logged by trigger-reflect.sh.
# The objective is to MINIMIZE the trigger rate. A version whose rate rose
# after a prompt change is evidence to revert that change.
import json
import os
import subprocess
import sys
from pathlib import Path

DEFAULT_REPO = str(Path(__file__).resolve().parent.parent)
REPO = os.path.expanduser(os.environ.get("INTROSPECT_REPO", DEFAULT_REPO))
AGENTS_HOME = os.path.expanduser(os.environ.get("AGENTS_HOME") or "~/.agents")
INTROSPECT_HOME = os.path.expanduser(os.environ.get("INTROSPECT_HOME") or "~/.introspect")


def default_feedback_dir():
    if REPO.endswith(".app/Contents/Resources"):
        return os.path.join(INTROSPECT_HOME, "feedback")
    return os.path.join(REPO, "feedback")


EVENTS = os.path.expanduser(os.environ.get("INTROSPECT_FEEDBACK_DIR", default_feedback_dir()))
EVENTS = os.path.join(EVENTS, "events.jsonl")

if not os.path.exists(EVENTS):
    print("No events logged yet.")
    sys.exit(0)

stats = {}   # version -> [prompts, triggers, first_ts, last_ts]
order = []
for line in open(EVENTS):
    try:
        e = json.loads(line)
    except Exception:
        continue
    v = e.get("version", "unknown")
    if v not in stats:
        stats[v] = [0, 0, e.get("ts", ""), e.get("ts", "")]
        order.append(v)
    s = stats[v]
    s[0] += 1
    s[1] += int(bool(e.get("triggered")))
    s[3] = e.get("ts", s[3])


def subject(version):
    try:
        return subprocess.run(
            ["git", "-C", REPO, "log", "-1", "--format=%s", version],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()[:60]
    except Exception:
        return ""


print(f"{'version':<10} {'prompts':>7} {'trig':>6} {'rate':>6}  first..last (UTC)        commit subject")
best = None
for v in order:
    p, f, first, last = stats[v]
    rate = f / p if p else 0.0
    if p >= 5 and (best is None or rate < best[1]):
        best = (v, rate)
    span = f"{first[5:16]}..{last[5:16]}"
    print(f"{v:<10} {p:>7} {f:>6} {rate:>6.1%}  {span:<24}  {subject(v)}")

if best:
    print(f"\nBest version with >=5 prompts: {best[0]} ({best[1]:.1%}). "
          f"To revert AGENTS.md to it: git -C {REPO} checkout {best[0]} -- AGENTS.md")
