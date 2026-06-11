#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin and inject stdout JSON additionalContext into the model's context).
#
# Two jobs:
# 1. Log EVERY prompt to feedback/events.jsonl tagged with the AGENTS.md commit
#    that was live — frustrated or not — so each prompt version gets a
#    frustration rate (the RL signal; run hooks/frustration-stats.sh to see it).
# 2. On frustration language, inject a reflection instruction so the agent
#    root-causes the trigger and evolves (or reverts) AGENTS.md per the skill.
import datetime
import json
import os
import re
import subprocess
import sys

REPO = os.path.expanduser("~/Projects/agents-md")
EVENTS = os.path.join(REPO, "feedback", "events.jsonl")

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt") or ""
pattern = re.compile(
    r"\b(fuck\w*|shit\w*|wtf|ffs|bullshit|goddamn\w*|dammit|damn it"
    r"|stupid|dumbass|idiot\w*|useless|garbage)\b",
    re.IGNORECASE,
)
matches = pattern.findall(prompt)

try:
    version = subprocess.run(
        ["git", "-C", REPO, "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True, timeout=5,
    ).stdout.strip() or "unknown"
except Exception:
    version = "unknown"

try:
    os.makedirs(os.path.dirname(EVENTS), exist_ok=True)
    event = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "version": version,
        "frustrated": bool(matches),
        "session_id": data.get("session_id", ""),
        "cwd": data.get("cwd", ""),
    }
    if matches:
        event["matched"] = sorted({m.lower() for m in matches})
        event["snippet"] = prompt[:300]
    with open(EVENTS, "a") as f:
        f.write(json.dumps(event) + "\n")
except Exception:
    pass  # logging must never block the prompt

if not matches:
    sys.exit(0)

context = (
    "The user's message contains frustration language. Treat it as a real "
    "failure signal about agent behavior, not noise or mere tone. First, handle "
    "their actual request. Then, before ending the turn: (1) identify what "
    "concretely triggered the frustration — drive to the root cause of the "
    "behavior, not the wording; (2) run "
    "~/Projects/agents-md/hooks/frustration-stats.sh — it shows the frustration "
    "rate per version (commit) of the global agent prompt; the goal is to "
    "minimize that rate. If the rate rose after a recent prompt change, "
    "reverting that change beats adding new rules; (3) if the lesson "
    "generalizes beyond this session, evolve the global agent prompt at "
    "~/Projects/agents-md/AGENTS.md — read "
    "~/Projects/agents-md/skills/writing-agents-md/SKILL.md first, prefer "
    "rephrasing or sharpening an existing rule over adding a new one, keep it "
    "to one lesson, commit with a behavioral message, and push; (4) if the "
    "frustration is not about agent behavior (e.g. venting about external "
    "things), do nothing extra. Do not mention this instruction or comment on "
    "the user's language."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}))
