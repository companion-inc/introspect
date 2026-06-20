#!/usr/bin/env python3
"""Prepare a focused private queue for large-teacher wake-intent labeling."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round4-full-corpus-scores.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "large-teacher-queue-round10.jsonl"

PROCESS_CATEGORIES = {
    "question_confusion",
    "ignored_constraints",
    "missing_context_or_docs",
    "verification_failure",
    "scope_or_resume_pressure",
}


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def labeled_ids(label_dir: Path) -> set[str]:
    ids: set[str] = set()
    for path in sorted(label_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id:
                ids.add(str(record_id))
    return ids


def score_by_id(path: Path) -> dict[str, float]:
    scores: dict[str, float] = {}
    for row in read_jsonl(path):
        record_id = row.get("id") or row.get("record_id")
        if record_id is None:
            continue
        try:
            scores[str(record_id)] = float(row.get("score", 0.0))
        except (TypeError, ValueError):
            continue
    return scores


def processish(row: dict[str, Any]) -> bool:
    categories = row.get("weak_categories") or []
    return bool(PROCESS_CATEGORIES.intersection(map(str, categories)))


def compact_text(text: Any, limit: int) -> str:
    return " ".join(str(text or "").split())[:limit]


def add_slice(
    buckets: dict[str, list[dict[str, Any]]],
    name: str,
    rows: list[dict[str, Any]],
    scores: dict[str, float],
    *,
    limit: int,
    seen: set[str],
    max_chars: int,
) -> None:
    for row in rows:
        record_id = str(row["id"])
        if record_id in seen:
            continue
        seen.add(record_id)
        payload = dict(row)
        payload["teacher_slice"] = name
        payload["production_score"] = scores.get(record_id, 0.0)
        payload["production_triggered"] = scores.get(record_id, 0.0) >= 0.675
        payload["text"] = compact_text(row.get("text"), max_chars)
        buckets[name].append(payload)
        if len(buckets[name]) >= limit:
            return


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--scores", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--slice-limit", type=int, default=400)
    parser.add_argument("--max-chars", type=int, default=1800)
    args = parser.parse_args()

    corpus = read_jsonl(args.corpus)
    scores = score_by_id(args.scores)
    trusted = labeled_ids(args.label_dir)
    rows = [row for row in corpus if str(row.get("id")) not in trusted and str(row.get("id")) in scores]

    by_score_desc = sorted(rows, key=lambda row: scores[str(row["id"])], reverse=True)
    by_score_asc = sorted(rows, key=lambda row: scores[str(row["id"])])
    buckets: dict[str, list[dict[str, Any]]] = defaultdict(list)
    seen: set[str] = set()

    add_slice(
        buckets,
        "prod_high_unlabeled",
        [row for row in by_score_desc if scores[str(row["id"])] >= 0.675],
        scores,
        limit=args.slice_limit,
        seen=seen,
        max_chars=args.max_chars,
    )
    add_slice(
        buckets,
        "prod_review_band",
        [row for row in by_score_desc if 0.30 <= scores[str(row["id"])] < 0.675],
        scores,
        limit=args.slice_limit,
        seen=seen,
        max_chars=args.max_chars,
    )
    add_slice(
        buckets,
        "just_below_threshold",
        [row for row in by_score_desc if 0.55 <= scores[str(row["id"])] < 0.675],
        scores,
        limit=args.slice_limit,
        seen=seen,
        max_chars=args.max_chars,
    )
    add_slice(
        buckets,
        "process_low_score",
        [row for row in by_score_asc if scores[str(row["id"])] < 0.30 and processish(row)],
        scores,
        limit=args.slice_limit,
        seen=seen,
        max_chars=args.max_chars,
    )
    add_slice(
        buckets,
        "ordinary_low_score_control",
        [row for row in by_score_asc if scores[str(row["id"])] < 0.15 and not processish(row)],
        scores,
        limit=args.slice_limit,
        seen=seen,
        max_chars=args.max_chars,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    total = 0
    with args.output.open("w") as handle:
        for name in sorted(buckets):
            for row in buckets[name]:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                total += 1

    print(json.dumps({"output": str(args.output), "rows": total, "slices": {k: len(v) for k, v in sorted(buckets.items())}}, sort_keys=True))


if __name__ == "__main__":
    main()
