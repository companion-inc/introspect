#!/usr/bin/python3
"""Shared event filters for direct user-authored Introspect wake signals."""

from __future__ import annotations

import datetime as dt
import hashlib
from typing import Any


CONTROL_PREFIXES = (
    "# agents.md instructions",
    "# files mentioned by the user:",
    "# files mentioned by user:",
    "## codex-clipboard-",
    "<codex_internal_context",
    "<environment_context>",
    "<instructions>",
    "<turn_aborted>",
    "you are the introspect trigger reflector.",
)


def compact_text(value: object) -> str:
    return " ".join(str(value or "").split())


def is_codex_control_message(prompt: str) -> bool:
    stripped = str(prompt or "").lstrip().lower()
    return any(stripped.startswith(prefix) for prefix in CONTROL_PREFIXES)


def event_text(event: dict[str, Any]) -> str:
    for key in ("prompt", "snippet"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value
    return ""


def event_counts_as_direct_user(event: dict[str, Any]) -> bool:
    role = compact_text(event.get("role")).lower()
    if role and role != "user":
        return False
    if is_codex_control_message(event_text(event)):
        return False
    return True


def parse_ts(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def event_count_key(event: dict[str, Any], *, bucket_seconds: int = 120) -> str:
    prompt_hash = compact_text(event.get("prompt_hash"))
    if not prompt_hash:
        text = event_text(event)
        prompt_hash = hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest() if text else ""
    ts = parse_ts(event.get("ts") or event.get("observed_at"))
    bucket = int(ts.timestamp() // bucket_seconds) if ts else 0
    raw = "\0".join(
        [
            compact_text(event.get("session_id")),
            compact_text(event.get("cwd")),
            prompt_hash,
            str(bucket),
        ]
    )
    if not prompt_hash:
        raw = compact_text(event.get("event_id") or event.get("dedupe_key")) or raw
    return hashlib.sha256(raw.encode("utf-8", errors="ignore")).hexdigest()
