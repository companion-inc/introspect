#!/usr/bin/python3
"""Local repetition-pressure scorer for review-tier Introspect wake events."""

from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import re
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

try:
    import fcntl
except Exception:  # pragma: no cover - fallback for non-POSIX development hosts.
    fcntl = None


VERSION = "repetition-pressure-v2"
DEFAULT_WINDOW_SECONDS = 30 * 60
DEFAULT_DUPLICATE_SECONDS = 10 * 60
DEFAULT_MIN_SIMILARITY = 0.46
DEFAULT_MIN_REPEATS = 2
DEFAULT_MIN_CHARS = 24
DEFAULT_MIN_TERMS = 4
MAX_ENTRIES_PER_SCOPE = 75
MAX_SEEN_KEYS = 5000

TOKEN_RE = re.compile(r"(?u)\b[\w']+\b")
PASTE_PREFIXES = (
    "# agents.md instructions",
    "<environment_context>",
    "<instructions>",
    "<codex_internal_context",
    "<turn_aborted>",
    "you are the introspect trigger reflector.",
)
CONTROL_PHRASES = {
    "continue",
    "go on",
    "keep going",
    "ok",
    "okay",
    "yes",
    "sure",
    "do it",
    "sounds good",
    "whatever",
}
STOPWORDS = {
    "a",
    "an",
    "and",
    "are",
    "as",
    "at",
    "be",
    "but",
    "by",
    "for",
    "from",
    "i",
    "in",
    "is",
    "it",
    "me",
    "my",
    "of",
    "on",
    "or",
    "our",
    "that",
    "the",
    "this",
    "to",
    "u",
    "we",
    "what",
    "with",
    "you",
    "your",
}


def compact_text(value: object) -> str:
    return " ".join(str(value or "").split())


def env_int(name: str, default: int, minimum: int) -> int:
    try:
        return max(minimum, int(os.environ.get(name, str(default))))
    except ValueError:
        return default


def env_float(name: str, default: float, minimum: float, maximum: float) -> float:
    try:
        value = float(os.environ.get(name, str(default)))
    except ValueError:
        return default
    return max(minimum, min(maximum, value))


def parse_ts(value: object) -> dt.datetime:
    if isinstance(value, str) and value:
        try:
            parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                return parsed.replace(tzinfo=dt.timezone.utc)
            return parsed.astimezone(dt.timezone.utc)
        except ValueError:
            pass
    return dt.datetime.now(dt.timezone.utc)


def iso_ts(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds")


def hash_value(value: str, *, length: int = 20) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="ignore")).hexdigest()[:length]


def normalized_tokens(text: str) -> list[str]:
    tokens: list[str] = []
    for token in TOKEN_RE.findall(text.lower()):
        token = token.strip("'")
        if len(token) < 2 or token in STOPWORDS:
            continue
        tokens.append(stem_token(token))
    return tokens


def stem_token(token: str) -> str:
    for suffix, min_len in (("ing", 6), ("ed", 5), ("es", 5), ("s", 5)):
        if token.endswith(suffix) and len(token) >= min_len:
            return token[: -len(suffix)]
    return token


def raw_features(text: str) -> set[str]:
    tokens = normalized_tokens(text)
    features = {f"w:{token}" for token in tokens}
    features.update(
        f"b:{tokens[index]} {tokens[index + 1]}"
        for index in range(0, max(0, len(tokens) - 1))
    )
    compact = " ".join(tokens)
    features.update(
        f"c:{compact[index:index + 4]}"
        for index in range(0, max(0, len(compact) - 3))
    )
    return features


def hashed_features(text: str) -> list[str]:
    return sorted(hash_value(f"{VERSION}\0{feature}") for feature in raw_features(text))


def jaccard(left: set[str], right: set[str]) -> float:
    if not left or not right:
        return 0.0
    return len(left & right) / len(left | right)


def is_control_phrase(text: str) -> bool:
    normalized = compact_text(text).lower()
    return normalized in CONTROL_PHRASES


def looks_like_pasted_context(text: str) -> bool:
    stripped = text.lstrip().lower()
    if any(stripped.startswith(prefix) for prefix in PASTE_PREFIXES):
        return True
    line_count = text.count("\n") + 1
    if len(text) > 1000 and line_count > 18:
        return True
    if len(text) > 500 and text.count("```") >= 2:
        return True
    return False


def scope_candidates(event: dict[str, Any]) -> list[tuple[str, str]]:
    cwd = compact_text(event.get("cwd"))
    transcript_path = compact_text(event.get("transcript_path"))
    raw_scopes: list[tuple[str, str]] = []
    if cwd:
        raw_scopes.append(("project", f"{VERSION}\0project\0{cwd}"))
    elif transcript_path:
        raw_scopes.append((
            "transcript_parent",
            f"{VERSION}\0transcript_parent\0{str(Path(transcript_path).parent)}",
        ))

    candidates: list[tuple[str, str]] = []
    seen: set[str] = set()
    for kind, raw in raw_scopes:
        key = hash_value(raw or "unknown-scope")
        if key in seen:
            continue
        seen.add(key)
        candidates.append((kind, key))
    return candidates


def duplicate_scope_id(event: dict[str, Any]) -> str:
    session_id = compact_text(event.get("session_id"))
    cwd = compact_text(event.get("cwd"))
    transcript_path = compact_text(event.get("transcript_path"))
    if not session_id and transcript_path:
        session_id = transcript_path
    return hash_value("\0".join([session_id, cwd]) or "unknown-duplicate-scope")


def message_key(event: dict[str, Any], prompt_hash: str) -> str:
    for name in ("message_locator", "dedupe_key", "event_id"):
        value = compact_text(event.get(name))
        if value:
            return f"{name}:{value}"
    return f"prompt_hash:{prompt_hash}"


def read_state(path: Path) -> dict[str, Any]:
    try:
        state = json.loads(path.read_text())
    except Exception:
        state = {}
    if not isinstance(state.get("scopes"), dict):
        state["scopes"] = {}
    if not isinstance(state.get("seen"), dict):
        state["seen"] = {}
    return state


def write_state(path: Path, state: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + f".{os.getpid()}.tmp")
    tmp.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n")
    os.replace(tmp, path)


@contextmanager
def locked_state(path: Path) -> Iterator[dict[str, Any]]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_suffix(path.suffix + ".lock")
    with lock_path.open("a+") as lock:
        if fcntl is not None:
            fcntl.flock(lock, fcntl.LOCK_EX)
        state = read_state(path)
        try:
            yield state
            write_state(path, state)
        finally:
            if fcntl is not None:
                fcntl.flock(lock, fcntl.LOCK_UN)


def prune_state(state: dict[str, Any], now: dt.datetime, window_seconds: int, duplicate_seconds: int) -> None:
    oldest_entry = now - dt.timedelta(seconds=window_seconds)
    scopes = state.get("scopes", {})
    for key, entries in list(scopes.items()):
        if not isinstance(entries, list):
            scopes.pop(key, None)
            continue
        kept = [
            entry
            for entry in entries
            if parse_ts(entry.get("ts")) >= oldest_entry
        ][-MAX_ENTRIES_PER_SCOPE:]
        if kept:
            scopes[key] = kept
        else:
            scopes.pop(key, None)

    oldest_seen = now - dt.timedelta(seconds=max(window_seconds, duplicate_seconds))
    seen = state.get("seen", {})
    if isinstance(seen, dict):
        rows = [
            (key, value)
            for key, value in seen.items()
            if parse_ts(value) >= oldest_seen
        ]
        rows.sort(key=lambda item: item[1], reverse=True)
        state["seen"] = dict(rows[:MAX_SEEN_KEYS])


def prompt_hash_for(prompt: str, event: dict[str, Any]) -> str:
    existing = compact_text(event.get("prompt_hash"))
    if existing:
        return existing
    return hashlib.sha256(prompt.encode("utf-8", errors="ignore")).hexdigest()


def duplicate_observation(
    entries: list[dict[str, Any]],
    *,
    now: dt.datetime,
    prompt_hash: str,
    duplicate_scope: str,
    duplicate_seconds: int,
) -> bool:
    cutoff = now - dt.timedelta(seconds=duplicate_seconds)
    for entry in reversed(entries):
        if entry.get("prompt_hash") != prompt_hash:
            continue
        if compact_text(entry.get("duplicate_scope")) != duplicate_scope:
            continue
        if parse_ts(entry.get("observed_at") or entry.get("ts")) < cutoff:
            continue
        return True
    return False


def score_repetition_pressure(
    prompt: str,
    event: dict[str, Any],
    classifier: dict[str, Any] | None,
    *,
    state_path: str | os.PathLike[str],
) -> dict[str, Any]:
    """Score and persist local review-tier repetition pressure for one prompt."""
    now = parse_ts(event.get("observed_at") or event.get("ts"))
    window_seconds = env_int("INTROSPECT_REPETITION_WINDOW_SECONDS", DEFAULT_WINDOW_SECONDS, 60)
    duplicate_seconds = env_int("INTROSPECT_REPETITION_DUPLICATE_SECONDS", DEFAULT_DUPLICATE_SECONDS, 30)
    min_similarity = env_float(
        "INTROSPECT_REPETITION_SIMILARITY",
        DEFAULT_MIN_SIMILARITY,
        0.01,
        0.99,
    )
    min_repeats = env_int("INTROSPECT_REPETITION_MIN_REPEATS", DEFAULT_MIN_REPEATS, 2)
    min_chars = env_int("INTROSPECT_REPETITION_MIN_CHARS", DEFAULT_MIN_CHARS, 1)
    min_terms = env_int("INTROSPECT_REPETITION_MIN_TERMS", DEFAULT_MIN_TERMS, 1)
    prompt_hash = prompt_hash_for(prompt, event)
    result: dict[str, Any] = {
        "version": VERSION,
        "triggered": False,
        "eligible": False,
        "score": 0.0,
        "similarity_threshold": min_similarity,
        "repeat_count": 1,
        "min_repeats": min_repeats,
        "window_seconds": window_seconds,
    }

    if os.environ.get("INTROSPECT_REPETITION_PRESSURE", "1") == "0":
        result["suppressed_reason"] = "disabled"
        return result
    if not classifier or "score" not in classifier:
        result["suppressed_reason"] = "classifier_unavailable"
        return result
    if is_control_phrase(prompt):
        result["suppressed_reason"] = "control_phrase"
        return result
    if looks_like_pasted_context(prompt):
        result["suppressed_reason"] = "pasted_context"
        return result
    tokens = normalized_tokens(prompt)
    if len(compact_text(prompt)) < min_chars or len(tokens) < min_terms:
        result["suppressed_reason"] = "too_short"
        return result

    try:
        classifier_score = float(classifier.get("score", 0.0))
    except (TypeError, ValueError):
        classifier_score = 0.0
    try:
        review_threshold = float(
            classifier.get("review_threshold")
            or os.environ.get("INTROSPECT_WAKE_REVIEW_THRESHOLD", "0.30")
        )
    except (TypeError, ValueError):
        review_threshold = 0.30
    classifier_review = bool(classifier.get("review")) or classifier_score >= review_threshold
    if not classifier_review:
        result["suppressed_reason"] = "below_review_threshold"
        result["classifier_score"] = classifier_score
        result["review_threshold"] = review_threshold
        return result
    scopes = scope_candidates(event)
    if not scopes:
        result["suppressed_reason"] = "project_scope_unavailable"
        result["classifier_score"] = classifier_score
        result["review_threshold"] = review_threshold
        return result

    features = set(hashed_features(prompt))
    if len(features) < min_terms:
        result["suppressed_reason"] = "too_few_features"
        return result

    duplicate_scope = duplicate_scope_id(event)
    locator = compact_text(event.get("message_locator") or event.get("dedupe_key"))
    has_locator = bool(locator)
    observation_key = hash_value(f"{duplicate_scope}\0{message_key(event, prompt_hash)}", length=32)
    path = Path(state_path)
    with locked_state(path) as state:
        prune_state(state, now, window_seconds, duplicate_seconds)
        seen = state.setdefault("seen", {})
        state_scopes = state.setdefault("scopes", {})
        scope_entries = [
            (kind, key, state_scopes.setdefault(key, []))
            for kind, key in scopes
        ]
        if observation_key in seen or duplicate_observation(
            [entry for _kind, _key, entries in scope_entries for entry in entries],
            now=now,
            prompt_hash=prompt_hash,
            duplicate_scope=duplicate_scope,
            duplicate_seconds=duplicate_seconds,
        ):
            result["eligible"] = True
            result["duplicate"] = True
            result["suppressed_reason"] = "duplicate_observation"
            return result

        best_scope_kind = scopes[0][0]
        best_scope_key = scopes[0][1]
        scored: list[tuple[float, dict[str, Any]]] = []
        for kind, key, entries in scope_entries:
            current_scored: list[tuple[float, dict[str, Any]]] = []
            for entry in entries:
                previous = set(entry.get("features") or [])
                similarity = jaccard(features, previous)
                if similarity >= min_similarity:
                    current_scored.append((similarity, entry))
            current_scored.sort(key=lambda item: item[0], reverse=True)
            if len(current_scored) > len(scored) or (
                len(current_scored) == len(scored)
                and current_scored
                and (not scored or current_scored[0][0] > scored[0][0])
            ):
                best_scope_kind = kind
                best_scope_key = key
                scored = current_scored
        repeat_count = 1 + len(scored)
        max_similarity = scored[0][0] if scored else 0.0
        result.update(
            {
                "eligible": True,
                "scope": best_scope_kind,
                "scope_id": best_scope_key,
                "score": round(max_similarity, 4),
                "repeat_count": repeat_count,
                "similar_count": len(scored),
                "similar_event_ids": [
                    compact_text(entry.get("event_id"))[:96]
                    for _similarity, entry in scored[:5]
                    if compact_text(entry.get("event_id"))
                ],
            }
        )
        if repeat_count >= min_repeats and not bool(classifier.get("triggered")):
            result["triggered"] = True

        current_entry = {
            "event_id": compact_text(event.get("event_id"))[:160],
            "ts": iso_ts(parse_ts(event.get("ts"))),
            "observed_at": iso_ts(now),
            "prompt_hash": prompt_hash,
            "has_locator": has_locator,
            "duplicate_scope": duplicate_scope,
            "score": classifier_score,
            "features": sorted(features),
        }
        for _kind, key, entries in scope_entries:
            entries.append(dict(current_entry))
            state["scopes"][key] = entries[-MAX_ENTRIES_PER_SCOPE:]
        seen[observation_key] = iso_ts(now)
        state["version"] = VERSION
        state["updated_at"] = iso_ts(now)
    return result
