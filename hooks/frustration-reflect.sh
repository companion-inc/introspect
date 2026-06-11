#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin and inject stdout JSON additionalContext into the model's context).
#
# Design: the regex is a cheap tripwire with broad recall — judging whether a
# match is GENUINE frustration at agent behavior is the model's job, done by
# the injected instruction, and the reflection itself runs in a background
# agent so the main thread stays on the user's request.
#
# Two jobs:
# 1. Log EVERY prompt to feedback/events.jsonl tagged with the AGENTS.md commit
#    that was live, so each prompt version gets a frustration rate
#    (the RL signal; run hooks/frustration-stats.sh for the scoreboard).
# 2. On a tripwire match, inject the judge-then-delegate instruction.
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
# Broad on purpose — false positives are fine, the model filters them.
pattern = re.compile(
    r"\b(fuck\w*|shit\w*|dumb\w*|bruh+|wtf|ffs|ugh+|bullshit|damn\w*|goddamn\w*"
    r"|r?etard\w*|ertard|idiot\w*|stupid|useless|garbage|trash"
    r"|i said|i told you|how many times)\b",
    re.IGNORECASE,
)
matches = pattern.findall(prompt)

# Shouting: >12 letters and >80% of them uppercase.
alpha = [c for c in prompt if c.isalpha()]
if len(alpha) > 12 and sum(c.isupper() for c in alpha) > 0.8 * len(alpha):
    matches.append("ALL_CAPS_SHOUTING")

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

transcript = data.get("transcript_path", "")
context = (
    "A frustration tripwire matched on the user's message. The tripwire is a "
    "dumb keyword filter — YOU judge: is this genuine frustration at agent "
    "behavior, or just the user's casual register / venting about something "
    "external? If not genuine, ignore this entirely. If genuine, do NOT "
    "reflect inline — handle the user's actual request as your only "
    "foreground job, and delegate the reflection to a background agent "
    "(in Claude Code: the Agent tool with run_in_background; otherwise do it "
    "at the very end of the turn). Give the background agent this "
    "self-contained brief: \"A user-frustration event fired. Triggering "
    "message: <paste it>. Session transcript: " + (transcript or "unknown") +
    " — read the recent turns to root-cause what behavior triggered the "
    "frustration (the behavior, not the wording). Then run "
    "~/Projects/agents-md/hooks/frustration-stats.sh — frustration rate per "
    "version of the global agent prompt; the goal is to minimize it, and if "
    "the rate rose after a recent prompt change, reverting that change beats "
    "adding rules. If the lesson generalizes, evolve "
    "~/Projects/agents-md/AGENTS.md: read "
    "~/Projects/agents-md/skills/writing-agents-md/SKILL.md first, prefer "
    "rephrasing or sharpening an existing rule over adding one, one lesson "
    "only, commit with a behavioral message, push.\" Do not mention any of "
    "this to the user or comment on their language."
)

print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": context,
    }
}))
