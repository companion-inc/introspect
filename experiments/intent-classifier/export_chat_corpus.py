#!/usr/bin/env python3
"""Export a deduped local Codex/Claude user-message corpus for intent evals."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_SAMPLE = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_REVIEW_TERMS_FILE = (
    Path(os.environ.get("INTROSPECT_HOME", Path.home() / ".introspect")) / "trigger-words.txt"
)

CODEX_FILES = [
    Path.home() / ".codex" / "sessions",
    Path.home() / ".codex" / "archived_sessions",
]
CLAUDE_FILES = [
    Path.home() / ".claude" / "transcripts",
    Path.home() / ".claude" / "projects",
]


@dataclass(frozen=True)
class Message:
    source: str
    timestamp: str
    text: str
    locator: str
    cwd: str = ""
    session_id: str = ""


def read_review_terms(path: Path = DEFAULT_REVIEW_TERMS_FILE) -> set[str]:
    if not path.exists():
        return set()
    terms: set[str] = set()
    for line in path.read_text().splitlines():
        term = line.strip().lower()
        if term and not term.startswith("#"):
            terms.add(term)
    return terms


def prompt_text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        chunks: list[str] = []
        for item in content:
            if not isinstance(item, dict):
                continue
            value = item.get("text") or item.get("content")
            if isinstance(value, str):
                chunks.append(value)
        return "\n".join(chunks)
    return ""


def is_control_message(text: str) -> bool:
    stripped = text.strip()
    if not stripped:
        return True
    control_prefixes = (
        "<environment_context>",
        "<user_instructions>",
        "<developer_instructions>",
        "<system_context>",
        "# AGENTS.md instructions",
        "We need answer",
        "We need respond",
    )
    if any(stripped.startswith(prefix) for prefix in control_prefixes):
        return True
    if stripped.startswith("<") and stripped.endswith(">") and "cwd" in stripped:
        return True
    return False


def strip_system_instruction(text: str) -> str:
    stripped = text.strip()
    if stripped.startswith("<system_instruction>"):
        end = stripped.find("</system_instruction>")
        if end >= 0:
            return stripped[end + len("</system_instruction>"):].strip()
    return text


def iter_jsonl(path: Path) -> Iterable[tuple[int, dict[str, Any]]]:
    try:
        with path.open(errors="ignore") as handle:
            for line_no, raw in enumerate(handle, 1):
                try:
                    row = json.loads(raw)
                except Exception:
                    continue
                if isinstance(row, dict):
                    yield line_no, row
    except OSError:
        return


def iter_codex_messages() -> Iterable[Message]:
    for root in CODEX_FILES:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.jsonl")):
            session_id = ""
            cwd = ""
            for line_no, row in iter_jsonl(path):
                timestamp = str(row.get("timestamp") or "")
                row_type = row.get("type")
                payload = row.get("payload")
                if row_type == "session_meta" and isinstance(payload, dict):
                    session_id = str(payload.get("id") or session_id)
                    cwd = str(payload.get("cwd") or cwd)
                    continue
                if row_type != "response_item" or not isinstance(payload, dict):
                    continue
                if payload.get("type") != "message" or payload.get("role") != "user":
                    continue
                text = prompt_text_from_content(payload.get("content")).strip()
                if is_control_message(text):
                    continue
                yield Message(
                    source="codex",
                    timestamp=timestamp,
                    text=text,
                    locator=f"{path}:{line_no}",
                    cwd=cwd,
                    session_id=session_id,
                )


def iter_claude_messages() -> Iterable[Message]:
    for root in CLAUDE_FILES:
        if not root.exists():
            continue
        for path in sorted(root.rglob("*.jsonl")):
            if "/subagents/" in str(path):
                continue
            for line_no, row in iter_jsonl(path):
                text = ""
                if row.get("isSidechain"):
                    continue
                if row.get("type") == "user":
                    message = row.get("message")
                    if isinstance(message, dict) and message.get("role") == "user":
                        text = prompt_text_from_content(message.get("content")).strip()
                    else:
                        text = prompt_text_from_content(row.get("content")).strip()
                elif row.get("type") == "queue-operation" and row.get("operation") == "enqueue":
                    text = prompt_text_from_content(row.get("content")).strip()
                if not text:
                    continue
                text = strip_system_instruction(text).strip()
                if is_control_message(text):
                    continue
                yield Message(
                    source="claude",
                    timestamp=str(row.get("timestamp") or ""),
                    text=text,
                    locator=f"{path}:{line_no}",
                    cwd=str(row.get("cwd") or ""),
                    session_id=str(row.get("sessionId") or row.get("session_id") or ""),
                )


def matched_words(text: str, words: set[str]) -> list[str]:
    return sorted({word for word in re.findall(r"[a-z]+", text.lower()) if word in words})


def weak_categories(text: str) -> list[str]:
    lower = text.lower()
    categories: list[str] = []
    patterns = {
        "question_confusion": [
            r"\bwhat'?s\b",
            r"\bwhy\b",
            r"\bhow\b",
            r"\bare you sure\b",
            r"\bconfused\b",
            r"\bdid you\b",
        ],
        "ignored_constraints": [
            r"\bwhy didn'?t you\b",
            r"\bdidn'?t\b.*\b(test|read|check|search|use|keep|follow)\b",
            r"\bi told you\b",
            r"\bwho said\b",
            r"\bstop\b.*\bdoing\b",
        ],
        "missing_context_or_docs": [
            r"\bread\b",
            r"\bchat history\b",
            r"\bfull chat\b",
            r"\bcontext\b",
            r"\bdocs?\b",
            r"\btranscript\b",
        ],
        "verification_failure": [
            r"\btest\b",
            r"\bverify\b",
            r"\bproof\b",
            r"\brepro\b",
            r"\bscreenshot\b",
        ],
        "scope_or_resume_pressure": [
            r"\bkeep going\b",
            r"\bcontinue\b",
            r"\bfinish\b",
            r"\bdone\b",
        ],
        "external_or_product_feedback": [
            r"\bui\b",
            r"\bux\b",
            r"\blooks\b",
            r"\bbutton\b",
            r"\bpadding\b",
            r"\berror\b",
            r"\bcrash\b",
        ],
    }
    for category, regexes in patterns.items():
        if any(re.search(pattern, lower) for pattern in regexes):
            categories.append(category)
    return categories


def weak_label(text: str, matches: list[str]) -> str:
    categories = set(weak_categories(text))
    if categories & {"ignored_constraints", "missing_context_or_docs", "verification_failure", "scope_or_resume_pressure"}:
        return "agent_failure_candidate"
    if matches and categories & {"question_confusion"}:
        return "needs_review"
    if matches:
        return "trigger_only"
    return "ordinary"


def stable_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", errors="ignore")).hexdigest()


def build_records(limit: int | None = None) -> list[dict[str, Any]]:
    review_terms = read_review_terms()
    seen: set[str] = set()
    records: list[dict[str, Any]] = []
    for message in list(iter_codex_messages()) + list(iter_claude_messages()):
        key = f"{message.source}:{stable_hash(message.text)}"
        if key in seen:
            continue
        seen.add(key)
        matches = matched_words(message.text, review_terms)
        categories = weak_categories(message.text)
        records.append(
            {
                "id": key,
                "source": message.source,
                "timestamp": message.timestamp,
                "locator": message.locator,
                "cwd": message.cwd,
                "session_id": message.session_id,
                "text": message.text,
                "text_hash": stable_hash(message.text),
                "char_count": len(message.text),
                "word_count": len(re.findall(r"\S+", message.text)),
                "old_trigger": bool(matches),
                "matched_words": matches,
                "weak_categories": categories,
                "weak_label": weak_label(message.text, matches),
            }
        )
        if limit and len(records) >= limit:
            break
    return records


def stratified_sample(records: list[dict[str, Any]], per_bucket: int) -> list[dict[str, Any]]:
    buckets: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        key = record["weak_label"]
        if record["old_trigger"] and record["weak_label"] == "ordinary":
            key = "old_trigger_ordinary"
        buckets.setdefault(key, []).append(record)

    sample: list[dict[str, Any]] = []
    for key in sorted(buckets):
        rows = sorted(buckets[key], key=lambda row: row["text_hash"])
        sample.extend(rows[:per_bucket])
    return sample


def write_jsonl(path: Path, rows: Iterable[dict[str, Any]]) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
            count += 1
    return count


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--sample-output", type=Path, default=DEFAULT_SAMPLE)
    parser.add_argument("--limit", type=int, default=0)
    parser.add_argument("--sample-per-bucket", type=int, default=300)
    args = parser.parse_args()

    records = build_records(limit=args.limit or None)
    sample = stratified_sample(records, args.sample_per_bucket)
    corpus_count = write_jsonl(args.output, records)
    sample_count = write_jsonl(args.sample_output, sample)

    by_source: dict[str, int] = {}
    by_label: dict[str, int] = {}
    trigger_count = 0
    for record in records:
        by_source[record["source"]] = by_source.get(record["source"], 0) + 1
        by_label[record["weak_label"]] = by_label.get(record["weak_label"], 0) + 1
        trigger_count += int(record["old_trigger"])

    print(
        json.dumps(
            {
                "corpus": str(args.output),
                "sample": str(args.sample_output),
                "records": corpus_count,
                "sample_records": sample_count,
                "old_trigger_records": trigger_count,
                "by_source": by_source,
                "by_weak_label": by_label,
            },
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
