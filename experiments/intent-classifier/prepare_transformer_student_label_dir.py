#!/usr/bin/env python3
"""Prepare hard labels plus teacher pseudo-labels for transformer student training."""

from __future__ import annotations

import argparse
import fnmatch
import json
import shutil
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def load_corpus_ids(path: Path) -> set[str]:
    ids: set[str] = set()
    for row in read_jsonl(path):
        record_id = row.get("id")
        if record_id:
            ids.add(str(record_id))
    return ids


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hard-label-dir", type=Path, required=True)
    parser.add_argument("--teacher-labels", type=Path, required=True)
    parser.add_argument("--corpus", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--holdout-pattern", action="append", default=None)
    parser.add_argument("--teacher-output-name", default="teacher_qwen3_next_80b_round10.jsonl")
    args = parser.parse_args()
    holdout_patterns = args.holdout_pattern or ["*round9*.jsonl"]

    corpus_ids = load_corpus_ids(args.corpus)
    args.output_dir.mkdir(parents=True, exist_ok=True)

    hard_ids: set[str] = set()
    holdout_ids: set[str] = set()
    copied_files = 0
    copied_rows = 0
    for source in sorted(args.hard_label_dir.glob("*.jsonl")):
        target = args.output_dir / source.name
        shutil.copy2(source, target)
        copied_files += 1
        is_holdout = any(fnmatch.fnmatch(source.name, pattern) for pattern in holdout_patterns)
        for row in read_jsonl(source):
            record_id = row.get("record_id")
            if not record_id:
                continue
            copied_rows += 1
            key = str(record_id)
            hard_ids.add(key)
            if is_holdout:
                holdout_ids.add(key)

    teacher_rows = read_jsonl(args.teacher_labels)
    teacher_path = args.output_dir / args.teacher_output_name
    added = 0
    skipped_hard = 0
    skipped_missing = 0
    skipped_invalid = 0
    wake_rows = 0
    no_wake_rows = 0
    with teacher_path.open("w") as handle:
        for row in teacher_rows:
            record_id = row.get("record_id")
            should_wake = row.get("should_wake")
            if not record_id or not isinstance(should_wake, bool) or row.get("error"):
                skipped_invalid += 1
                continue
            key = str(record_id)
            if key in hard_ids:
                skipped_hard += 1
                continue
            if key not in corpus_ids:
                skipped_missing += 1
                continue
            out = {
                "record_id": key,
                "should_wake": should_wake,
                "source": "qwen3-next-80b-a3b-fp8",
                "wake_label": row.get("wake_label"),
                "route_label": row.get("route_label"),
                "wake_probability": row.get("wake_probability"),
                "confidence": row.get("confidence"),
            }
            handle.write(json.dumps(out, ensure_ascii=False) + "\n")
            added += 1
            if should_wake:
                wake_rows += 1
            else:
                no_wake_rows += 1

    print(
        json.dumps(
            {
                "copied_files": copied_files,
                "copied_rows": copied_rows,
                "hard_unique_ids": len(hard_ids),
                "holdout_unique_ids": len(holdout_ids),
                "teacher_input_rows": len(teacher_rows),
                "teacher_added_rows": added,
                "teacher_added_wakes": wake_rows,
                "teacher_added_no_wakes": no_wake_rows,
                "teacher_skipped_hard_label": skipped_hard,
                "teacher_skipped_missing_corpus": skipped_missing,
                "teacher_skipped_invalid": skipped_invalid,
                "output_dir": str(args.output_dir),
                "teacher_file": str(teacher_path),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
