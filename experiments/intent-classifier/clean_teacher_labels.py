#!/usr/bin/env python3
"""Write a deduped teacher-label JSONL, preferring successful labels over errors."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    chosen: dict[str, dict[str, Any]] = {}
    raw_rows = read_jsonl(args.input)
    for row in raw_rows:
        record_id = row.get("record_id")
        if not record_id:
            continue
        key = str(record_id)
        current = chosen.get(key)
        if current is None or (current.get("error") and not row.get("error")):
            chosen[key] = row

    cleaned = [row for _record_id, row in sorted(chosen.items())]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as handle:
        for row in cleaned:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    print(
        json.dumps(
            {
                "input": str(args.input),
                "output": str(args.output),
                "raw_rows": len(raw_rows),
                "unique_records": len(cleaned),
                "errors": sum(1 for row in cleaned if row.get("error")),
                "wakes": sum(1 for row in cleaned if row.get("should_wake") is True),
                "no_wakes": sum(1 for row in cleaned if row.get("should_wake") is False),
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
