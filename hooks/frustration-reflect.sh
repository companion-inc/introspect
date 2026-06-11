#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin).
#
# Design: the regex is a cheap tripwire with broad recall — judging whether a
# match is GENUINE frustration at agent behavior is the reflector's job, done
# out-of-band by hooks/frustration-worker.py. The foreground model never gets a
# spawned-agent instruction from this hook.
#
# Two jobs:
# 1. Log EVERY prompt to feedback/events.jsonl tagged with the AGENTS.md commit
#    that was live, so each prompt version gets a frustration rate
#    (the RL signal; run hooks/frustration-stats.sh for the scoreboard).
# 2. On a tripwire match, enqueue the event and kick the single-worker batch
#    reflector. The worker handles debouncing, cooldowns, and locking.
import datetime
import json
import os
import re
import subprocess
import sys

if os.environ.get("AGENTS_MD_REFLECTOR") == "1":
    # The background reflector prompt contains frustration snippets. Do not let
    # the reflector recursively trigger itself.
    sys.exit(0)

REPO = os.path.expanduser(os.environ.get("AGENTS_MD_REPO", "~/Projects/agents-md"))
FEEDBACK_DIR = os.path.expanduser(
    os.environ.get("AGENTS_MD_FEEDBACK_DIR", os.path.join(REPO, "feedback"))
)
EVENTS = os.path.join(FEEDBACK_DIR, "events.jsonl")
QUEUE = os.path.join(FEEDBACK_DIR, "frustration-queue.jsonl")
WORKER = os.path.join(REPO, "hooks", "frustration-worker.py")

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt") or ""
# Broad on purpose — false positives are fine, the model filters them.
pattern = re.compile(
    r"\b(fuck\w*|shit\w*|dumb\w*|dumbfuck\w*|bruh+|wtf|ffs|ugh+|bullshit"
    r"|damn\w*|goddamn\w*|r?etard\w*|ertard|idiot\w*|stupid|useless"
    r"|garbage|trash|moron\w*|clown\w*|asshole\w*|bitch\w*|cunt\w*"
    r"|fag\w*|nigg\w*|dipshit\w*|brain[- ]?dead|i said|i told you"
    r"|how many times)\b",
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


def json_append(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "a") as f:
        f.write(json.dumps(obj, ensure_ascii=False) + "\n")


def pick(*names):
    for name in names:
        value = data.get(name)
        if value:
            return value
    return ""


try:
    event = {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "version": version,
        "frustrated": bool(matches),
        "session_id": pick("session_id", "sessionId"),
        "cwd": pick("cwd"),
        "transcript_path": pick("transcript_path", "transcriptPath"),
    }
    if matches:
        event["matched"] = sorted({m.lower() for m in matches})
        event["snippet"] = prompt[:300]
    json_append(EVENTS, event)
except Exception:
    pass  # logging must never block the prompt

if not matches:
    sys.exit(0)

try:
    queued = dict(event)
    queued["prompt"] = prompt[:4000]
    json_append(QUEUE, queued)
except Exception:
    sys.exit(0)

try:
    subprocess.Popen(
        [sys.executable, WORKER, "--kick"],
        cwd=REPO,
        env=os.environ.copy(),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
except Exception:
    try:
        json_append(
            os.path.join(FEEDBACK_DIR, "reflector-launch-errors.jsonl"),
            {
                "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                "worker": WORKER,
            },
        )
    except Exception:
        pass
