#!/bin/bash
# Compatibility wrapper. The real architecture is queue -> locked batch worker,
# not one reflector per message.
set -euo pipefail

TRANSCRIPT="${1:-}"
MESSAGE="${2:-}"
REPO="${AGENTS_MD_REPO:-$HOME/Projects/self-healing-agent-md}"
FEEDBACK_DIR="${AGENTS_MD_FEEDBACK_DIR:-$REPO/feedback}"
QUEUE="$FEEDBACK_DIR/frustration-queue.jsonl"

mkdir -p "$FEEDBACK_DIR"
python3 - "$QUEUE" "$TRANSCRIPT" "$MESSAGE" <<'PY'
import datetime
import json
import sys

queue, transcript, message = sys.argv[1:4]
event = {
    "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "version": "manual-launch",
    "frustrated": True,
    "session_id": "",
    "cwd": "",
    "transcript_path": transcript,
    "matched": ["manual"],
    "snippet": message[:300],
    "prompt": message[:4000],
}
with open(queue, "a") as f:
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
PY

nohup python3 "$REPO/hooks/frustration-worker.py" --kick \
  >> "$FEEDBACK_DIR/reflector.log" 2>&1 </dev/null &
disown 2>/dev/null || true
echo "queued reflector batch; worker lock/cooldown controls launch"
