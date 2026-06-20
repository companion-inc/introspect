#!/usr/bin/env python3
"""Validate Introspect subagent label files against their input packs."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise SystemExit(f"Missing file: {path}")
    rows: list[dict[str, Any]] = []
    with path.open() as handle:
        for line_number, raw in enumerate(handle, 1):
            if not raw.strip():
                continue
            try:
                rows.append(json.loads(raw))
            except json.JSONDecodeError as error:
                raise SystemExit(f"{path}:{line_number}: invalid JSON: {error}") from error
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("labels", type=Path)
    args = parser.parse_args()

    inputs = read_jsonl(args.input)
    labels = read_jsonl(args.labels)
    if len(inputs) != len(labels):
        raise SystemExit(f"Row count mismatch: input={len(inputs)} labels={len(labels)}")

    input_ids = [str(row.get("record_id") or "") for row in inputs]
    label_ids = [str(row.get("record_id") or "") for row in labels]
    if len(set(input_ids)) != len(input_ids):
        raise SystemExit("Input contains duplicate record_id values")
    if len(set(label_ids)) != len(label_ids):
        raise SystemExit("Labels contain duplicate record_id values")
    if input_ids != label_ids:
        for index, (expected, actual) in enumerate(zip(input_ids, label_ids), 1):
            if expected != actual:
                raise SystemExit(f"Order mismatch at row {index}: expected={expected} actual={actual}")
        raise SystemExit("Label IDs do not match input IDs")

    required = {"record_id", "should_wake", "wake_label", "route_label", "confidence", "reason"}
    wakes = 0
    for index, row in enumerate(labels, 1):
        missing = sorted(required - set(row))
        if missing:
            raise SystemExit(f"Row {index} missing keys: {', '.join(missing)}")
        if not isinstance(row.get("should_wake"), bool):
            raise SystemExit(f"Row {index} should_wake is not boolean")
        confidence = row.get("confidence")
        if not isinstance(confidence, (int, float)) or not 0 <= float(confidence) <= 1:
            raise SystemExit(f"Row {index} confidence is not in [0, 1]")
        if not str(row.get("wake_label") or "").strip():
            raise SystemExit(f"Row {index} wake_label is empty")
        if not str(row.get("route_label") or "").strip():
            raise SystemExit(f"Row {index} route_label is empty")
        if not str(row.get("reason") or "").strip():
            raise SystemExit(f"Row {index} reason is empty")
        wakes += int(row["should_wake"])

    print(json.dumps({"rows": len(labels), "wakes": wakes, "no_wakes": len(labels) - wakes, "labels": str(args.labels)}, sort_keys=True))


if __name__ == "__main__":
    main()
