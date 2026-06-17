#!/usr/bin/env python3
# UserPromptSubmit hook (Claude Code + Codex — both deliver {"prompt": ...} on
# stdin).
#
# Design: the local classifier decides whether a prompt is a foreground wake.
# Optional review terms are metadata only unless an explicit emergency fallback
# flag is set. The foreground model never gets a spawned-agent instruction from
# this hook.
#
# Two jobs:
# 1. Log EVERY prompt to feedback/events.jsonl tagged with the AGENTS.md commit
#    that was live, so each prompt version gets a trigger rate
#    (the RL signal; run hooks/trigger-stats.sh for the scoreboard).
# 2. On a classifier wake, enqueue the event and, in immediate mode, kick the
#    single-worker batch reflector. The worker handles debouncing, cooldowns,
#    and locking. Nightly mode queues only; off mode logs only.
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from intent_classifier import score_prompt
except Exception:
    score_prompt = None

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


def normalize_words(values):
    words = set()
    for value in values:
        if isinstance(value, str):
            normalized = value.strip().lower()
            if re.fullmatch(r"[a-z]+", normalized):
                words.add(normalized)
    return words


def active_trigger_words():
    try:
        with open(TRIGGER_WORDS_FILE) as f:
            return normalize_words(f.read().splitlines())
    except Exception:
        return set()


TRIGGER_WORDS = active_trigger_words()
matches = sorted({word for word in re.findall(r"[a-z]+", prompt.lower()) if word in TRIGGER_WORDS})
classifier = None
classifier_enabled = os.environ.get("INTROSPECT_WAKE_CLASSIFIER", "1") != "0"
if classifier_enabled and score_prompt is not None:
    try:
        classifier = score_prompt(
            prompt,
            source=data.get("source") or ("codex" if "codex" in (data.get("transcript_path") or "").lower() else "claude"),
            old_trigger=bool(matches),
            matched_words=matches,
        )
    except Exception as exc:
        classifier = {"error": f"{type(exc).__name__}: {str(exc)[:160]}"}
classifier_triggered = bool(classifier and classifier.get("triggered"))
classifier_available = bool(classifier and "score" in classifier)
word_fallback_enabled = os.environ.get("INTROSPECT_TRIGGER_WORD_FALLBACK", "0") == "1"
triggered = classifier_triggered if classifier_available else (bool(matches) and word_fallback_enabled)
wake_reason = "classifier" if classifier_available else (
    "trigger_word_fallback" if word_fallback_enabled else "classifier_unavailable"
)

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


event = None
try:
    session_id = pick("session_id", "sessionId")
    transcript_path = pick("transcript_path", "transcriptPath")
    transcript_line = pick("transcript_line", "transcriptLine")
    source_message_id = pick("message_id", "messageId", "id")
    prompt_hash = hashlib.sha256(prompt.encode("utf-8", errors="ignore")).hexdigest()
    event_id = source_message_id or "|".join(
        part for part in [session_id, transcript_path, str(transcript_line or ""), prompt_hash] if part
    )
    event = {
        "event_id": event_id or prompt_hash,
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "source": "hook",
        "version": version,
        "triggered": triggered,
        "wake_reason": wake_reason,
        "review_triggered": bool(matches) or bool(classifier and classifier.get("review")),
        "session_id": session_id,
        "cwd": pick("cwd"),
        "transcript_path": transcript_path,
        "prompt_hash": prompt_hash,
    }
    if classifier:
        event["classifier"] = classifier
    if transcript_line:
        event["transcript_line"] = transcript_line
    if transcript_path and transcript_line:
        event["message_locator"] = f"{transcript_path}:{transcript_line}"
    elif source_message_id:
        event["message_locator"] = source_message_id
    if matches:
        event["matched"] = matches
    if matches or triggered or event.get("review_triggered"):
        event["snippet"] = prompt[:300]
    json_append(EVENTS, event)
except Exception:
    pass  # logging must never block the prompt

if not triggered:
    sys.exit(0)

if REFLECT_MODE == "off":
    sys.exit(0)

try:
    queued = dict(event or {
        "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "source": "hook",
        "version": version,
        "triggered": triggered,
        "wake_reason": wake_reason,
        "session_id": pick("session_id", "sessionId"),
        "cwd": pick("cwd"),
        "snippet": prompt[:300],
    })
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
