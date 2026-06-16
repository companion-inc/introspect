#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin).
#
# Design: the regex is a cheap trigger with broad recall — judging whether a
# match is GENUINE trigger at agent behavior is the reflector's job, done
# out-of-band by hooks/trigger-worker.py. The foreground model never gets a
# spawned-agent instruction from this hook.
#
# Two jobs:
# 1. Log EVERY prompt to feedback/events.jsonl tagged with the AGENTS.md commit
#    that was live, so each prompt version gets a trigger rate
#    (the RL signal; run hooks/trigger-stats.sh for the scoreboard).
# 2. On a trigger match, enqueue the event and, in immediate mode, kick the
#    single-worker batch reflector. The worker handles debouncing, cooldowns,
#    and locking. Nightly mode queues only; off mode logs only.
import datetime
import json
import os
import re
import subprocess
import sys

if os.environ.get("INTROSPECT_REFLECTOR") == "1":
    # The background reflector prompt contains trigger snippets. Do not let
    # the reflector recursively trigger itself.
    sys.exit(0)

REPO = os.path.expanduser(os.environ.get("INTROSPECT_REPO", "~/Companion/Code/introspect"))
FEEDBACK_DIR = os.path.expanduser(
    os.environ.get("INTROSPECT_FEEDBACK_DIR", os.path.join(REPO, "feedback"))
)
EVENTS = os.path.join(FEEDBACK_DIR, "events.jsonl")
QUEUE = os.path.join(FEEDBACK_DIR, "trigger-queue.jsonl")
WORKER = os.path.join(REPO, "hooks", "trigger-worker.py")
INTROSPECT_HOME = os.path.expanduser(
    os.environ.get("INTROSPECT_HOME") or "~/.introspect"
)
TRIGGER_WORDS_FILE = os.path.join(INTROSPECT_HOME, "trigger-words.txt")
REFLECT_MODE = (
    os.environ.get("INTROSPECT_REFLECT_MODE") or "immediate"
).strip().lower()

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

prompt = data.get("prompt") or ""
# Exact words only. No prefix matching and no phrase triggers. Common filler
# terms stay out of this list; regression tests cover known false positives.
DEFAULT_TRIGGER_WORDS = {
    "arse",
    "ass",
    "asshole",
    "bastard",
    "bitch",
    "bullshit",
    "crap",
    "cunt",
    "damn",
    "dipshit",
    "dumb",
    "dumbass",
    "dumbfuck",
    "fag",
    "faggot",
    "ffs",
    "fuck",
    "fucked",
    "fucker",
    "fuckin",
    "fucking",
    "goddamn",
    "hell",
    "idiot",
    "mf",
    "moron",
    "motherfucker",
    "motherfucking",
    "nigga",
    "nigger",
    "retard",
    "retarded",
    "shitty",
    "stupid",
    "wtf",
}


def normalize_words(values):
    words = set()
    for value in values:
        if isinstance(value, str):
            normalized = value.strip().lower()
            if re.fullmatch(r"[a-z]+", normalized):
                words.add(normalized)
    return words


def active_trigger_words():
    words = set(DEFAULT_TRIGGER_WORDS)
    try:
        with open(TRIGGER_WORDS_FILE) as f:
            home_words = normalize_words(f.read().splitlines())
    except Exception:
        return words

    return home_words or words


TRIGGER_WORDS = active_trigger_words()
matches = [word for word in re.findall(r"[a-z]+", prompt.lower()) if word in TRIGGER_WORDS]

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
        "triggered": bool(matches),
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

if REFLECT_MODE == "off":
    sys.exit(0)

try:
    queued = dict(event)
    queued["prompt"] = prompt[:4000]
    json_append(QUEUE, queued)
except Exception:
    sys.exit(0)

if REFLECT_MODE != "immediate":
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
