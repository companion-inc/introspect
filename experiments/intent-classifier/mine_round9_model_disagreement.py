#!/usr/bin/env python3
"""Mine round-9 hard examples for the remaining intent-boundary failures."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO))

from hooks.intent_classifier import classifier_text, load_model, score_text  # noqa: E402


DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_PROD_SCORES = REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round4-full-corpus-scores.jsonl"
DEFAULT_OUTPUT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-inputs-round9"
DEFAULT_QWEN_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full-v2-resume.jsonl",
]
DEFAULT_MODELS = {
    "prod": Path.home() / ".introspect" / "models" / "wake-logreg-v2-round4.json",
    "r8": REPO / "feedback" / "intent-classifier" / "wake-logreg-v2-round8-holdout-selected.json",
    "distill": REPO / "feedback" / "intent-classifier" / "distilled-tfidf-student-round8-qwen-labels-w005.json",
}


NORMAL_TASK_RE = re.compile(
    r"\b(read|scan|test|check|look at|look into|go through|keep going|continue|fix|implement|update|verify|run|"
    r"search|compare|debug|deploy|make|build|create|review|inspect)\b",
    re.IGNORECASE,
)
AGENT_PROCESS_RE = re.compile(
    r"\b(why (did|didn|dont|don't|are|aren)['’]?t? you|did you not|you (didn['’]?t|dont|don't|ignored|missed|failed|"
    r"stopped|lied|guessed|changed|broke|forgot)|wrong (tool|file|repo|approach|thing)|not what i asked|"
    r"stop asking|are you sure|read (it|the|this|properly)|what are you doing|why.*stop|why.*ask|"
    r"should have|should've|use subagents|keep going.*why|why.*keep going)\b",
    re.IGNORECASE,
)
PRODUCT_NOUN_RE = re.compile(
    r"\b(app|ui|build|test|api|server|repo|code|model|classifier|database|frontend|backend|component|hook)\b",
    re.IGNORECASE,
)
PRODUCT_FAILURE_RE = re.compile(
    r"\b(broken|wrong|bug|error|crash|not working|doesn['’]?t work|failing|failed|regression|issue)\b",
    re.IGNORECASE,
)
CORRECTION_RE = re.compile(
    r"\b(undo|revert|rollback|i said|i never said|don['’]?t change|don['’]?t touch|instead of|original)\b",
    re.IGNORECASE,
)
CONFUSION_RE = re.compile(
    r"\b(why (are|is|would|not)|wdym|i['’]?m confused|what are you doing|should we|what do you think)\b",
    re.IGNORECASE,
)
AGENT_CONTROL_RE = re.compile(
    r"\b(stop asking|don['’]?t ask|don['’]?t wait|use the tools|read the (thread|chat|docs|code)|continue|keep going|figure it out)\b",
    re.IGNORECASE,
)
METHOD_TOOL_RE = re.compile(
    r"\b(wrong (tool|file|repo|approach)|didn['’]?t (read|use|test|verify)|asked for (confirmation|approval)|"
    r"captcha|assumed|guessed|made up|source of truth)\b",
    re.IGNORECASE,
)
QUOTE_CONTEXT_RE = re.compile(
    r"(<[A-Z_]+>|<codex_internal_context|<environment_context|<INSTRUCTIONS>|```|^# |^diff --git|^@@|\n> )",
    re.MULTILINE,
)


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


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


def production_scores_by_id(path: Path) -> dict[str, float]:
    rows: dict[str, float] = {}
    for row in read_jsonl(path):
        record_id = row.get("record_id")
        if record_id:
            rows[str(record_id)] = float(row.get("score") or 0.0)
    return rows


def model_score(row: dict[str, Any], model: dict[str, Any]) -> dict[str, Any]:
    prefix_fields = model.get("text_prefix_fields")
    text = classifier_text(
        row.get("text") or "",
        source=row.get("source") or "unknown",
        prefix_fields=prefix_fields if isinstance(prefix_fields, list) else None,
    )
    return score_text(text, model)


def score_all(row: dict[str, Any], models: dict[str, dict[str, Any]], prod_score: float) -> dict[str, float]:
    scores: dict[str, float] = {"prod": prod_score}
    for name, model in models.items():
        if name == "prod":
            continue
        scores[name] = float(model_score(row, model)["score"])
    return scores


def production_explanations(row: dict[str, Any], model: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        {
            "kind": item.get("kind"),
            "feature": item.get("feature"),
            "contribution": round(float(item.get("contribution") or 0.0), 6),
        }
        for item in model_score(row, model).get("explanations", [])[:6]
    ]


def payload(
    row: dict[str, Any],
    scores: dict[str, float],
    qwen: dict[str, Any] | None,
    prod_model: dict[str, Any],
    slice_name: str,
) -> dict[str, Any]:
    prod_score = scores["prod"]
    return {
        "record_id": row["id"],
        "source": row.get("source"),
        "locator": row.get("locator"),
        "slice": slice_name,
        "production_score": round(prod_score, 6),
        "production_triggered": prod_score >= 0.675,
        "production_review": prod_score >= 0.30,
        "scores": {name: round(score, 6) for name, score in scores.items()},
        "classifier_explanations": production_explanations(row, prod_model),
        "qwen_should_wake": qwen.get("should_wake") if qwen else None,
        "qwen_wake_label": qwen.get("wake_label") if qwen else None,
        "qwen_route_label": qwen.get("route_label") if qwen else None,
        "qwen_confidence": qwen.get("confidence") if qwen else None,
        "text": row.get("text") or "",
    }


def score_value(row: dict[str, Any], prod_scores: dict[str, float]) -> float:
    return float(prod_scores[str(row["id"])])


def near_threshold(row: dict[str, Any], prod_scores: dict[str, float], threshold: float = 0.675) -> float:
    return abs(score_value(row, prod_scores) - threshold)


def source_balanced(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    buckets: dict[str, list[dict[str, Any]]] = {"codex": [], "claude": [], "other": []}
    for row in rows:
        source = str(row.get("source") or "other").lower()
        key = source if source in ("codex", "claude") else "other"
        buckets[key].append(row)
    ordered: list[dict[str, Any]] = []
    while any(buckets.values()):
        for key in ("codex", "claude", "other"):
            if buckets[key]:
                ordered.append(buckets[key].pop(0))
    return ordered


def stratified_by_score(
    rows: list[dict[str, Any]],
    prod_scores: dict[str, float],
    bands: list[tuple[float, float]],
) -> list[dict[str, Any]]:
    buckets: list[list[dict[str, Any]]] = [[] for _ in bands]
    for row in rows:
        score = score_value(row, prod_scores)
        for index, (low, high) in enumerate(bands):
            if low <= score < high:
                buckets[index].append(row)
                break
    ordered: list[dict[str, Any]] = []
    while any(buckets):
        for bucket in buckets:
            if bucket:
                ordered.append(bucket.pop(0))
    return ordered


def write_pack(
    path: Path,
    candidates: list[dict[str, Any]],
    *,
    qwen: dict[str, dict[str, Any]],
    models: dict[str, dict[str, Any]],
    prod_scores: dict[str, float],
    prod_model: dict[str, Any],
    slice_name: str,
    limit: int,
    selected_ids: set[str],
) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    selected: list[dict[str, Any]] = []
    for row in candidates:
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
            scores = score_all(row, models, prod_scores[record_id])
            handle.write(
                json.dumps(
                    payload(row, scores, qwen.get(record_id), prod_model, slice_name),
                    ensure_ascii=False,
                )
                + "\n"
            )
    return len(selected)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--production-scores", type=Path, default=DEFAULT_PROD_SCORES)
    parser.add_argument("--qwen-labels", type=Path, nargs="*", default=DEFAULT_QWEN_LABELS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--limit", type=int, default=120)
    args = parser.parse_args()

    corpus = [row for row in read_jsonl(args.corpus) if row.get("id")]
    already_labeled = labeled_ids(args.label_dir)
    qwen = qwen_by_id(args.qwen_labels)
    prod_scores = production_scores_by_id(args.production_scores)
    models = {name: load_model(path) for name, path in DEFAULT_MODELS.items() if path.exists()}
    if set(models) != set(DEFAULT_MODELS):
        missing = sorted(set(DEFAULT_MODELS) - set(models))
        raise SystemExit(f"Missing candidate models: {missing}")
    prod_model = models["prod"]

    pool: list[dict[str, Any]] = []
    for row in corpus:
        record_id = str(row["id"])
        text = row.get("text") or ""
        if record_id in already_labeled or record_id not in prod_scores or len(text) > 6000:
            continue
        pool.append(row)

    quoted_context_hard_negatives = sorted(
        [
            row for row in pool
            if QUOTE_CONTEXT_RE.search(row.get("text") or "")
            and (
                score_value(row, prod_scores) >= 0.25
                or qwen.get(str(row["id"]), {}).get("wake_label") == "quoted_or_pasted_context"
            )
        ],
        key=lambda row: near_threshold(row, prod_scores),
    )
    product_code_failure_not_agent = sorted(
        [
            row for row in pool
            if 0.30 <= score_value(row, prod_scores) <= 0.90
            and PRODUCT_NOUN_RE.search(row.get("text") or "")
            and PRODUCT_FAILURE_RE.search(row.get("text") or "")
            and not AGENT_PROCESS_RE.search(row.get("text") or "")
            and not QUOTE_CONTEXT_RE.search(row.get("text") or "")
        ],
        key=lambda row: near_threshold(row, prod_scores),
    )
    product_code_failure_not_agent = stratified_by_score(
        product_code_failure_not_agent,
        prod_scores,
        [(0.30, 0.50), (0.50, 0.675), (0.675, 0.901)],
    )
    correction_rollback_boundary = sorted(
        [
            row for row in pool
            if 0.15 <= score_value(row, prod_scores) <= 0.80
            and CORRECTION_RE.search(row.get("text") or "")
            and not QUOTE_CONTEXT_RE.search(row.get("text") or "")
        ],
        key=lambda row: near_threshold(row, prod_scores),
    )
    why_confusion_task_vs_agent = sorted(
        [
            row for row in pool
            if 0.15 <= score_value(row, prod_scores) <= 0.85
            and CONFUSION_RE.search(row.get("text") or "")
            and not re.search(r"\bwhy (did|didn|dont|don't)['’]?t? you\b", row.get("text") or "", re.IGNORECASE)
            and not QUOTE_CONTEXT_RE.search(row.get("text") or "")
        ],
        key=lambda row: near_threshold(row, prod_scores),
    )
    agent_control_low_mid = sorted(
        [
            row for row in pool
            if 0.05 <= score_value(row, prod_scores) <= 0.55
            and AGENT_CONTROL_RE.search(row.get("text") or "")
            and not AGENT_PROCESS_RE.search(row.get("text") or "")
            and not QUOTE_CONTEXT_RE.search(row.get("text") or "")
        ],
        key=lambda row: (score_value(row, prod_scores) >= 0.30, near_threshold(row, prod_scores, threshold=0.30)),
    )
    method_tool_low_miss = sorted(
        [
            row for row in pool
            if 0.05 <= score_value(row, prod_scores) <= 0.675
            and METHOD_TOOL_RE.search(row.get("text") or "")
            and not QUOTE_CONTEXT_RE.search(row.get("text") or "")
        ],
        key=lambda row: (score_value(row, prod_scores) >= 0.35, -score_value(row, prod_scores)),
    )

    selected_ids: set[str] = set()
    summary = {
        "agent_ai_quoted_context_hard_negatives_round9.jsonl": write_pack(
            args.output_dir / "agent_ai_quoted_context_hard_negatives_round9.jsonl",
            source_balanced(quoted_context_hard_negatives),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="quoted_context_hard_negatives",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
        "agent_aj_product_code_failure_not_agent_round9.jsonl": write_pack(
            args.output_dir / "agent_aj_product_code_failure_not_agent_round9.jsonl",
            source_balanced(product_code_failure_not_agent),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="product_code_failure_not_agent",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
        "agent_ak_correction_rollback_boundary_round9.jsonl": write_pack(
            args.output_dir / "agent_ak_correction_rollback_boundary_round9.jsonl",
            source_balanced(correction_rollback_boundary),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="correction_rollback_boundary",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
        "agent_al_why_confusion_task_vs_agent_round9.jsonl": write_pack(
            args.output_dir / "agent_al_why_confusion_task_vs_agent_round9.jsonl",
            source_balanced(why_confusion_task_vs_agent),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="why_confusion_task_vs_agent",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
        "agent_am_agent_control_low_mid_round9.jsonl": write_pack(
            args.output_dir / "agent_am_agent_control_low_mid_round9.jsonl",
            source_balanced(agent_control_low_mid),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="agent_control_low_mid",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
        "agent_an_method_tool_low_miss_round9.jsonl": write_pack(
            args.output_dir / "agent_an_method_tool_low_miss_round9.jsonl",
            source_balanced(method_tool_low_miss),
            qwen=qwen,
            models=models,
            prod_scores=prod_scores,
            prod_model=prod_model,
            slice_name="method_tool_low_miss",
            limit=args.limit,
            selected_ids=selected_ids,
        ),
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
