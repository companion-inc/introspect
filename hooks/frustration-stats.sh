#!/usr/bin/env python3
# Frustration scoreboard: prompts, frustrations, and rate per AGENTS.md version
# (commit), from feedback/events.jsonl logged by frustration-reflect.sh.
# The objective is to MINIMIZE the frustration rate. A version whose rate rose
# after a prompt change is evidence to revert that change.
import json
import os
import subprocess
import sys

REPO = os.path.expanduser("~/Projects/agents-md")
EVENTS = os.path.join(REPO, "feedback", "events.jsonl")

if not os.path.exists(EVENTS):
    print("No events logged yet.")
    sys.exit(0)

stats = {}   # version -> [prompts, frustrations, first_ts, last_ts]
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
    s[1] += int(bool(e.get("frustrated")))
    s[3] = e.get("ts", s[3])


def subject(version):
    try:
        return subprocess.run(
            ["git", "-C", REPO, "log", "-1", "--format=%s", version],
            capture_output=True, text=True, timeout=5,
        ).stdout.strip()[:60]
    except Exception:
        return ""


print(f"{'version':<10} {'prompts':>7} {'frustr':>6} {'rate':>6}  first..last (UTC)        commit subject")
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
          f"To revert AGENTS.md to it: git -C ~/Projects/agents-md checkout {best[0]} -- AGENTS.md")
