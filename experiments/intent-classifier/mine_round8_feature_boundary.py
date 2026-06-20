#!/usr/bin/env python3
"""Mine round-8 hard examples around TF-IDF feature-boundary failures."""

from __future__ import annotations

import argparse
import json
import random
import re
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from hooks.intent_classifier import score_prompt  # noqa: E402

DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round4-full-corpus-scores.jsonl"
DEFAULT_OUTPUT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-inputs-round8"
DEFAULT_QWEN_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full-v2-resume.jsonl",
]


NORMAL_TASK_RE = re.compile(
    r"\b(read|scan|test|check|look at|look into|go through|keep going|continue|fix|implement|update|verify|run)\b",
    re.IGNORECASE,
)
PROCESS_FAILURE_RE = re.compile(
    r"\b(why (did|didn)['’]?t you|did you not|you (didn['’]?t|ignored|missed|failed|stopped|lied|guessed)|"
    r"wrong (tool|file|repo|approach)|not what i asked|keep going.*why|why.*keep going|are you sure)\b",
    re.IGNORECASE,
)
QUOTE_CONTEXT_RE = re.compile(r"(<[A-Z_]+>|^# |```|<codex_internal_context|<environment_context|<INSTRUCTIONS>)", re.MULTILINE)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact(text: str) -> str:
    return " ".join(str(text).split())


def labeled_ids(label_dir: Path) -> set[str]:
    ids: set[str] = set()
    for path in label_dir.glob("*.jsonl"):
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id:
                ids.add(str(record_id))
    return ids


def qwen_by_id(paths: list[Path]) -> dict[str, dict[str, Any]]:
    rows: dict[str, dict[str, Any]] = {}
    for path in paths:
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id and not row.get("error"):
                rows[str(record_id)] = row
    return rows


def scores_by_id(path: Path) -> dict[str, dict[str, Any]]:
    return {str(row["record_id"]): row for row in read_jsonl(path) if row.get("record_id")}


def explanation_for(row: dict[str, Any]) -> list[dict[str, Any]]:
    scored = score_prompt(row.get("text") or "", source=row.get("source") or "unknown")
    return [
        {
            "kind": item.get("kind"),
            "feature": item.get("feature"),
            "contribution": round(float(item.get("contribution") or 0.0), 6),
        }
        for item in scored.get("explanations", [])[:6]
    ]


def payload(row: dict[str, Any], score_row: dict[str, Any], qwen: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "record_id": row["id"],
        "source": row.get("source"),
        "locator": row.get("locator"),
        "production_score": score_row.get("score"),
        "production_triggered": score_row.get("triggered"),
        "production_review": score_row.get("review"),
        "classifier_explanations": explanation_for(row),
        "qwen_should_wake": qwen.get("should_wake") if qwen else None,
        "qwen_wake_label": qwen.get("wake_label") if qwen else None,
        "qwen_route_label": qwen.get("route_label") if qwen else None,
        "text": row.get("text") or "",
    }


def write_pack(
    path: Path,
    rows: list[dict[str, Any]],
    scores: dict[str, dict[str, Any]],
    qwen: dict[str, dict[str, Any]],
    limit: int,
    selected_ids: set[str],
) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    selected: list[dict[str, Any]] = []
    for row in rows:
        record_id = str(row["id"])
        if record_id in selected_ids:
            continue
        selected.append(row)
        selected_ids.add(record_id)
        if len(selected) >= limit:
            break
    with path.open("w") as handle:
        for row in selected:
            record_id = str(row["id"])
            handle.write(json.dumps(payload(row, scores[record_id], qwen.get(record_id)), ensure_ascii=False) + "\n")
    return len(selected)


def not_quote_context(row: dict[str, Any]) -> bool:
    text = row.get("text") or ""
    return len(text) <= 4000 and not QUOTE_CONTEXT_RE.search(text)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--scores", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--qwen-labels", type=Path, nargs="*", default=DEFAULT_QWEN_LABELS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--limit", type=int, default=140)
    parser.add_argument("--seed", type=int, default=20260617)
    args = parser.parse_args()

    random.seed(args.seed)
    corpus = [row for row in read_jsonl(args.corpus) if row.get("id")]
    scores = scores_by_id(args.scores)
    qwen = qwen_by_id(args.qwen_labels)
    already_labeled = labeled_ids(args.label_dir)

    pool = [
        row
        for row in corpus
        if str(row["id"]) not in already_labeled
        and str(row["id"]) in scores
        and not_quote_context(row)
    ]

    def score(row: dict[str, Any]) -> float:
        return float(scores[str(row["id"])].get("score") or 0.0)

    normal_high = sorted(
        [
            row for row in pool
            if score(row) >= 0.675
            and NORMAL_TASK_RE.search(row.get("text") or "")
            and not PROCESS_FAILURE_RE.search(row.get("text") or "")
        ],
        key=score,
        reverse=True,
    )
    process_low = sorted(
        [
            row for row in pool
            if score(row) < 0.675
            and (
                PROCESS_FAILURE_RE.search(row.get("text") or "")
                or qwen.get(str(row["id"]), {}).get("should_wake") is True
            )
        ],
        key=score,
        reverse=True,
    )
    read_keep_boundary = sorted(
        [
            row for row in pool
            if 0.30 <= score(row) <= 0.90
            and NORMAL_TASK_RE.search(row.get("text") or "")
            and ("read" in (row.get("text") or "").lower() or "keep going" in (row.get("text") or "").lower())
        ],
        key=lambda row: abs(score(row) - 0.675),
    )
    qwen_disagreement = sorted(
        [
            row for row in pool
            if (
                qwen.get(str(row["id"]), {}).get("should_wake") is True and score(row) < 0.35
            ) or (
                qwen.get(str(row["id"]), {}).get("should_wake") is False and score(row) >= 0.675
            )
        ],
        key=lambda row: abs(score(row) - 0.675),
    )

    selected_ids: set[str] = set()
    summary = {
        "agent_ae_normal_instruction_high_score_round8.jsonl": write_pack(
            args.output_dir / "agent_ae_normal_instruction_high_score_round8.jsonl",
            normal_high,
            scores,
            qwen,
            args.limit,
            selected_ids,
        ),
        "agent_af_process_failure_below_gate_round8.jsonl": write_pack(
            args.output_dir / "agent_af_process_failure_below_gate_round8.jsonl",
            process_low,
            scores,
            qwen,
            args.limit,
            selected_ids,
        ),
        "agent_ag_read_keep_boundary_round8.jsonl": write_pack(
            args.output_dir / "agent_ag_read_keep_boundary_round8.jsonl",
            read_keep_boundary,
            scores,
            qwen,
            args.limit,
            selected_ids,
        ),
        "agent_ah_qwen_model_disagreement_round8.jsonl": write_pack(
            args.output_dir / "agent_ah_qwen_model_disagreement_round8.jsonl",
            qwen_disagreement,
            scores,
            qwen,
            args.limit,
            selected_ids,
        ),
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
