#!/usr/bin/python3
"""PostHog telemetry for Introspect runtime events.

Telemetry is deliberately narrower than transcript sync. The payload contains
classifier and runtime metadata, stable local hashes for correlation, and no raw
transcript text unless the user explicitly selects redacted snippet mode.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import platform
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path
from typing import Any


INTROSPECT_HOME = Path(os.path.expanduser(os.environ.get("INTROSPECT_HOME") or "~/.introspect"))
SETTINGS = INTROSPECT_HOME / "settings.json"
TELEMETRY_DIR = Path(
    os.path.expanduser(os.environ.get("INTROSPECT_TELEMETRY_DIR", str(INTROSPECT_HOME / "telemetry")))
)
QUEUE = TELEMETRY_DIR / "queue.jsonl"
STATE = TELEMETRY_DIR / "state.json"
DEFAULT_HOST = "https://us.i.posthog.com"
DEFAULT_EVENT = "introspect.feedback_event"
MAX_BATCH_SIZE = int(os.environ.get("INTROSPECT_TELEMETRY_BATCH_SIZE", "50"))
HTTP_TIMEOUT = float(os.environ.get("INTROSPECT_TELEMETRY_TIMEOUT", "4"))


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_now() -> str:
    return utc_now().isoformat(timespec="seconds")


def read_json(path: Path, default: Any) -> Any:
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


def append_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as f:
        f.write(json.dumps(payload, ensure_ascii=False) + "\n")


def parse_bool(value: object, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    normalized = str(value).strip().lower()
    if normalized in {"1", "true", "yes", "y", "on", "enabled", "basic", "redacted"}:
        return True
    if normalized in {"0", "false", "no", "n", "off", "disabled", "none", "never"}:
        return False
    return default


def clean_mode(value: object) -> str:
    mode = str(value or "basic").strip().lower()
    if mode in {"", "on", "enabled", "true", "1"}:
        return "basic"
    if mode in {"off", "disabled", "false", "0", "none", "never"}:
        return "off"
    if mode in {"basic", "redacted"}:
        return mode
    return "basic"


def telemetry_config() -> dict[str, Any]:
    settings = read_json(SETTINGS, {})
    if not isinstance(settings, dict):
        settings = {}

    mode = clean_mode(os.environ.get("INTROSPECT_TELEMETRY_MODE", settings.get("telemetry_mode", "basic")))
    enabled = parse_bool(
        os.environ.get("INTROSPECT_TELEMETRY", settings.get("telemetry_enabled", True)),
        True,
    )
    if mode == "off":
        enabled = False

    token = (
        os.environ.get("INTROSPECT_POSTHOG_TOKEN")
        or os.environ.get("INTROSPECT_POSTHOG_PROJECT_TOKEN")
        or os.environ.get("INTROSPECT_POSTHOG_KEY")
        or settings.get("telemetry_project_token")
        or settings.get("posthog_project_token")
        or ""
    )
    host = (
        os.environ.get("INTROSPECT_POSTHOG_HOST")
        or os.environ.get("INTROSPECT_POSTHOG_API_HOST")
        or settings.get("telemetry_host")
        or DEFAULT_HOST
    )
    return {
        "enabled": bool(enabled),
        "mode": mode,
        "token": str(token).strip(),
        "host": str(host).strip().rstrip("/") or DEFAULT_HOST,
    }


def persistent_secret(name: str) -> str:
    path = TELEMETRY_DIR / name
    try:
        value = path.read_text().strip()
        if value:
            return value
    except OSError:
        pass
    TELEMETRY_DIR.mkdir(parents=True, exist_ok=True)
    value = uuid.uuid4().hex
    path.write_text(value + "\n")
    try:
        path.chmod(0o600)
    except OSError:
        pass
    return value


def distinct_id() -> str:
    configured = os.environ.get("INTROSPECT_TELEMETRY_DISTINCT_ID", "").strip()
    if configured:
        return configured
    return "introspect:" + persistent_secret("machine-id")


def digest(value: object, *, salt: bool = True) -> str:
    text = str(value or "")
    if not text:
        return ""
    h = hashlib.sha256()
    if salt:
        h.update(persistent_secret("salt").encode())
        h.update(b"\0")
    h.update(text.encode("utf-8", errors="ignore"))
    return h.hexdigest()


SECRET_PATTERNS = [
    re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"),
    re.compile(r"https?://[^\s)>\]}\"']+"),
    re.compile(r"\b(?:sk|pk|phc|pha|ghp|github_pat|xox[baprs]?|dtn|sm)[_-][A-Za-z0-9_=-]{8,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
]


def redacted_snippet(text: object) -> str:
    snippet = str(text or "")[:300]
    home = str(Path.home())
    if home:
        snippet = snippet.replace(home, "~")
    snippet = re.sub(r"/Users/[^/\s]+", "/Users/[user]", snippet)
    for pattern in SECRET_PATTERNS:
        snippet = pattern.sub("[redacted]", snippet)
    return " ".join(snippet.split())


def classifier_props(classifier: object) -> dict[str, Any]:
    if not isinstance(classifier, dict):
        return {}
    props: dict[str, Any] = {}
    for key in (
        "score",
        "threshold",
        "review_threshold",
        "triggered",
        "review",
        "wake_sensitivity",
        "effective_threshold",
        "model_id",
        "model_type",
    ):
        if key in classifier:
            value = classifier.get(key)
            if isinstance(value, float):
                value = round(value, 6)
            props[f"classifier_{key}"] = value
    alternates = classifier.get("alternates")
    if isinstance(alternates, list):
        props["classifier_alternate_count"] = len(alternates)
    return props


def build_feedback_capture(event: dict[str, Any], *, mode: str) -> dict[str, Any]:
    snippet = str(event.get("snippet") or event.get("prompt") or "")
    event_id = str(event.get("event_id") or event.get("dedupe_key") or event.get("prompt_hash") or "")
    repetition = event.get("repetition_pressure")
    properties: dict[str, Any] = {
        "$insert_id": digest(event_id or json.dumps(event, sort_keys=True)[:1000]),
        "$lib": "introspect",
        "telemetry_schema": 1,
        "source": event.get("source"),
        "role": event.get("role") or "user",
        "version": event.get("version"),
        "triggered": bool(event.get("triggered")),
        "review_triggered": bool(event.get("review_triggered")),
        "backfilled": bool(event.get("backfilled")),
        "wake_reason": event.get("wake_reason"),
        "has_snippet": bool(snippet),
        "snippet_length": len(snippet),
        "snippet_sha256": digest(snippet, salt=False) if snippet else "",
        "matched_count": len(event.get("matched") or []),
        "cwd_hash": digest(event.get("cwd")),
        "session_hash": digest(event.get("session_id")),
        "transcript_hash": digest(event.get("transcript_path")),
        "message_locator_hash": digest(event.get("message_locator")),
        "prompt_hash": event.get("prompt_hash"),
        "platform": platform.system().lower(),
        "python": platform.python_version(),
    }
    if isinstance(repetition, dict):
        properties["repetition_triggered"] = bool(repetition.get("triggered"))
        properties["repetition_repeat_count"] = repetition.get("repeat_count")
        properties["repetition_duplicate"] = bool(repetition.get("duplicate"))
    properties.update(classifier_props(event.get("classifier")))
    if mode == "redacted" and snippet:
        properties["snippet_redacted"] = redacted_snippet(snippet)

    return {
        "event": DEFAULT_EVENT,
        "distinct_id": distinct_id(),
        "timestamp": event.get("observed_at") or event.get("ts") or iso_now(),
        "properties": {k: v for k, v in properties.items() if v not in ("", None)},
    }


def queue_capture(capture: dict[str, Any]) -> None:
    append_json(QUEUE, capture)


def read_queue(limit: int) -> tuple[list[dict[str, Any]], list[str]]:
    try:
        lines = QUEUE.read_text().splitlines()
    except OSError:
        return [], []
    captures: list[dict[str, Any]] = []
    kept: list[str] = []
    for line in lines:
        if not line.strip():
            continue
        if len(captures) >= limit:
            kept.append(line)
            continue
        try:
            payload = json.loads(line)
        except Exception:
            continue
        if isinstance(payload, dict):
            captures.append(payload)
    return captures, kept


def replace_queue(remaining: list[str]) -> None:
    if remaining:
        QUEUE.parent.mkdir(parents=True, exist_ok=True)
        QUEUE.write_text("\n".join(remaining) + "\n")
    else:
        try:
            QUEUE.unlink()
        except FileNotFoundError:
            pass


def post_batch(host: str, token: str, captures: list[dict[str, Any]]) -> tuple[bool, str]:
    payload = json.dumps({"api_key": token, "batch": captures}).encode()
    url = host.rstrip("/") + "/batch/"
    request = urllib.request.Request(
        url,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT) as response:
            ok = 200 <= response.status < 300
            return ok, f"http_{response.status}"
    except Exception as urllib_exc:
        curl = "/usr/bin/curl"
        if not Path(curl).exists():
            return False, f"{type(urllib_exc).__name__}: {str(urllib_exc)[:120]}"
        try:
            result = subprocess.run(
                [
                    curl,
                    "--silent",
                    "--show-error",
                    "--fail",
                    "--max-time",
                    str(max(int(HTTP_TIMEOUT), 1)),
                    "-H",
                    "Content-Type: application/json",
                    "--data-binary",
                    "@-",
                    url,
                ],
                input=payload,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                check=False,
            )
        except Exception as curl_exc:
            return False, f"{type(curl_exc).__name__}: {str(curl_exc)[:120]}"
        if result.returncode == 0:
            return True, "curl_2xx"
        return False, (result.stderr.decode(errors="replace") or f"curl_exit_{result.returncode}")[:160]


def update_state(**updates: Any) -> None:
    state = read_json(STATE, {})
    if not isinstance(state, dict):
        state = {}
    state.update(updates)
    state["updated_at"] = iso_now()
    write_json(STATE, state)


def flush_queue(*, limit: int = MAX_BATCH_SIZE) -> tuple[int, str]:
    config = telemetry_config()
    if not config["enabled"]:
        update_state(enabled=False, last_status="disabled")
        return 0, "disabled"
    if not config["token"]:
        update_state(enabled=True, configured=False, last_status="missing_project_token")
        return 0, "missing_project_token"
    captures, remaining = read_queue(max(limit, 1))
    if not captures:
        update_state(enabled=True, configured=True, last_status="empty")
        return 0, "empty"
    ok, status = post_batch(config["host"], config["token"], captures)
    if not ok:
        update_state(enabled=True, configured=True, last_status=status, last_error_at=iso_now())
        return 0, status
    replace_queue(remaining)
    update_state(
        enabled=True,
        configured=True,
        last_status=status,
        last_flush_at=iso_now(),
        last_flush_count=len(captures),
    )
    return len(captures), status


def background_flush() -> None:
    if os.environ.get("INTROSPECT_TELEMETRY_NO_BACKGROUND") == "1":
        return
    try:
        subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "flush"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env=os.environ.copy(),
        )
    except Exception:
        pass


def capture_feedback_event(event: dict[str, Any], *, flush: bool = False, background: bool = False) -> None:
    config = telemetry_config()
    if not config["enabled"] or not config["token"]:
        return
    capture = build_feedback_capture(event, mode=config["mode"])
    queue_capture(capture)
    if flush:
        flush_queue()
    elif background:
        background_flush()


def status_payload() -> dict[str, Any]:
    config = telemetry_config()
    state = read_json(STATE, {})
    try:
        queued = sum(1 for line in QUEUE.read_text().splitlines() if line.strip())
    except OSError:
        queued = 0
    return {
        "enabled": bool(config["enabled"]),
        "configured": bool(config["token"]),
        "mode": config["mode"],
        "host": config["host"],
        "queued": queued,
        "last_status": state.get("last_status") if isinstance(state, dict) else None,
        "last_flush_at": state.get("last_flush_at") if isinstance(state, dict) else None,
        "last_flush_count": state.get("last_flush_count") if isinstance(state, dict) else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("status")
    flush_parser = sub.add_parser("flush")
    flush_parser.add_argument("--limit", type=int, default=MAX_BATCH_SIZE)
    args = parser.parse_args()
    if args.command == "flush":
        count, status = flush_queue(limit=args.limit)
        print(json.dumps({"sent": count, "status": status}, sort_keys=True))
        return 0
    print(json.dumps(status_payload(), indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
