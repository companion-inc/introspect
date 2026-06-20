#!/usr/bin/env python3
"""Backfill wake-classifier shadow scores into historical Introspect events."""

from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "hooks"))

from intent_classifier import score_shadow_models, shadow_model_specs  # noqa: E402


DEFAULT_EVENTS = REPO / "feedback" / "events.jsonl"
SCANNER_PATH = REPO / "hooks" / "codex-transcript-scan.py"


scanner_spec = importlib.util.spec_from_file_location("codex_transcript_scan", SCANNER_PATH)
if scanner_spec is None or scanner_spec.loader is None:
    raise RuntimeError(f"could not load scanner helper from {SCANNER_PATH}")
scanner = importlib.util.module_from_spec(scanner_spec)
scanner_spec.loader.exec_module(scanner)
is_codex_control_message = scanner.is_codex_control_message
prompt_text_from_content = scanner.prompt_text_from_content


def utc_stamp() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read_jsonl_preserve(path: Path) -> list[tuple[str, dict[str, Any] | None]]:
    rows: list[tuple[str, dict[str, Any] | None]] = []
    if not path.exists():
        return rows
    with path.open() as handle:
        for raw in handle:
            try:
                parsed = json.loads(raw)
            except Exception:
                rows.append((raw, None))
                continue
            rows.append((raw, parsed if isinstance(parsed, dict) else None))
    return rows


def transcript_prompt(event: dict[str, Any]) -> str:
    path_raw = event.get("transcript_path")
    line_raw = event.get("transcript_line")
    if not path_raw or line_raw is None:
        return ""
    try:
        line_no = int(line_raw)
    except (TypeError, ValueError):
        return ""
    if line_no <= 0:
        return ""

    path = Path(os.path.expanduser(str(path_raw)))
    if not path.exists():
        return ""
    try:
        with path.open(errors="ignore") as handle:
            for index, raw in enumerate(handle, 1):
                if index != line_no:
                    continue
                row = json.loads(raw)
                payload = row.get("payload")
                if not isinstance(payload, dict):
                    return ""
                if payload.get("type") != "message" or payload.get("role") != "user":
                    return ""
                prompt = prompt_text_from_content(payload.get("content"))
                if is_codex_control_message(prompt):
                    return ""
                return prompt
    except Exception:
        return ""
    return ""


def event_prompt(event: dict[str, Any], *, allow_snippet: bool) -> tuple[str, str]:
    prompt = event.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        return prompt, "prompt"

    prompt = transcript_prompt(event)
    if prompt.strip():
        return prompt, "transcript"

    snippet = event.get("snippet")
    if allow_snippet and isinstance(snippet, str) and snippet.strip():
        return snippet, "snippet"

    return "", "missing"


def scorer_source(event: dict[str, Any]) -> str:
    source = str(event.get("source") or "")
    if source == "codex_transcript_scan":
        return "codex"
    if source == "hook":
        path = str(event.get("transcript_path") or "").lower()
        return "codex" if "codex" in path else "claude"
    return source or "unknown"


def backfill(
    events_path: Path,
    *,
    allow_snippet: bool,
    force: bool,
    dry_run: bool,
) -> dict[str, Any]:
    rows = read_jsonl_preserve(events_path)
    stats = {
        "events_path": str(events_path),
        "rows": len(rows),
        "classifier_scored": 0,
        "already_had_alternates": 0,
        "missing_text": 0,
        "backfilled": 0,
        "errors": 0,
        "prompt_sources": {},
        "shadow_models": [name for name, _path in shadow_model_specs()],
    }
    if not stats["shadow_models"]:
        raise SystemExit("No shadow models configured. Set INTROSPECT_WAKE_SHADOW_MODELS or pass the env through install-hooks.")

    changed_rows: list[str] = []
    backfilled_at = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")

    for raw, event in rows:
        if event is None:
            changed_rows.append(raw)
            continue
        classifier = event.get("classifier")
        if not isinstance(classifier, dict) or "score" not in classifier:
            changed_rows.append(raw)
            continue

        stats["classifier_scored"] += 1
        if classifier.get("alternates") and not force:
            stats["already_had_alternates"] += 1
            changed_rows.append(raw)
            continue

        prompt, prompt_source = event_prompt(event, allow_snippet=allow_snippet)
        stats["prompt_sources"][prompt_source] = int(stats["prompt_sources"].get(prompt_source, 0)) + 1
        if not prompt:
            stats["missing_text"] += 1
            changed_rows.append(raw)
            continue

        try:
            alternates = score_shadow_models(
                prompt,
                source=scorer_source(event),
                old_trigger=bool(event.get("matched")),
                matched_words=event.get("matched") if isinstance(event.get("matched"), list) else [],
            )
        except Exception:
            stats["errors"] += 1
            changed_rows.append(raw)
            continue
        if not alternates:
            changed_rows.append(raw)
            continue

        classifier["alternates"] = alternates
        classifier["alternates_backfilled_at"] = backfilled_at
        classifier["alternates_prompt_source"] = prompt_source
        event["classifier"] = classifier
        stats["backfilled"] += 1
        changed_rows.append(json.dumps(event, ensure_ascii=False, sort_keys=False) + "\n")

    if stats["backfilled"] and not dry_run:
        backup = events_path.with_name(f"{events_path.name}.shadow-backfill-{utc_stamp()}.bak")
        backup.write_bytes(events_path.read_bytes())
        tmp = events_path.with_name(f"{events_path.name}.{os.getpid()}.tmp")
        tmp.write_text("".join(changed_rows))
        os.replace(tmp, events_path)
        stats["backup"] = str(backup)

    return stats


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--events", type=Path, default=DEFAULT_EVENTS)
    parser.add_argument("--allow-snippet", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    stats = backfill(
        args.events,
        allow_snippet=args.allow_snippet,
        force=args.force,
        dry_run=args.dry_run,
    )
    print(json.dumps(stats, sort_keys=True))


if __name__ == "__main__":
    main()
