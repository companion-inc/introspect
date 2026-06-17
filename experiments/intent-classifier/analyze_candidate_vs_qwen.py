#!/usr/bin/env python3
"""Compare candidate model scores against Qwen intent labels."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_LABELS = REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "candidate-scores-fast-2000.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "candidate-vs-qwen-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def score_for(scores: list[dict[str, Any]], wanted: set[str]) -> float:
    best = 0.0
    wanted = {w.lower() for w in wanted}
    for item in scores:
        label = str(item.get("label") or "").lower()
        score = float(item.get("score") or 0)
        if label in wanted:
            best = max(best, score)
    return best


def top_score(scores: list[dict[str, Any]]) -> tuple[str, float]:
    best_label = ""
    best_score = -1.0
    for item in scores:
        score = float(item.get("score") or 0)
        if score > best_score:
            best_label = str(item.get("label") or "")
            best_score = score
    return best_label, best_score


def candidate_score(model_name: str, scores: list[dict[str, Any]]) -> float:
    if model_name == "twitter_sentiment":
        return score_for(scores, {"negative"})
    if model_name == "go_emotions":
        return max(score_for(scores, {"anger"}), score_for(scores, {"annoyance"}), score_for(scores, {"disapproval"}), score_for(scores, {"confusion"}))
    if model_name == "emotion_distilroberta":
        return max(score_for(scores, {"anger"}), score_for(scores, {"disgust"}), score_for(scores, {"sadness"}))
    if model_name == "toxic_bert":
        return max(score_for(scores, {"toxic", "severe_toxic", "insult", "obscene"}), score_for(scores, {"label_1"}))
    if model_name == "toxic_distilbert":
        return max(score_for(scores, {"toxic"}), score_for(scores, {"label_1"}))
    if model_name == "generic_intent":
        return top_score(scores)[1]
    return 0.0


def metric_at_threshold(rows: list[dict[str, Any]], threshold: float) -> dict[str, float]:
    tp = fp = fn = tn = 0
    for row in rows:
        truth = bool(row["should_wake"])
        pred = row["candidate_score"] >= threshold
        if truth and pred:
            tp += 1
        elif truth and not pred:
            fn += 1
        elif not truth and pred:
            fp += 1
        else:
            tn += 1
    precision = tp / (tp + fp) if tp + fp else 0.0
    recall = tp / (tp + fn) if tp + fn else 0.0
    wake_rate = (tp + fp) / len(rows) if rows else 0.0
    return {"threshold": threshold, "precision": precision, "recall": recall, "wake_rate": wake_rate, "tp": tp, "fp": fp, "fn": fn, "tn": tn}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
    parser.add_argument("--scores", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    labels = {row["record_id"]: row for row in read_jsonl(args.labels) if "error" not in row}
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for score in read_jsonl(args.scores):
        label = labels.get(score["record_id"])
        if not label:
            continue
        scores = score.get("scores") or []
        if not isinstance(scores, list):
            scores = []
        grouped[score["model_name"]].append(
            {
                "record_id": score["record_id"],
                "should_wake": bool(label.get("should_wake")),
                "wake_label": label.get("wake_label"),
                "candidate_score": candidate_score(score["model_name"], scores),
                "top_label": top_score(scores)[0],
            }
        )

    lines = ["# Candidate Models vs Qwen Labels", ""]
    for model_name in sorted(grouped):
        rows = grouped[model_name]
        lines.append(f"## {model_name}")
        lines.append("")
        lines.append(f"Rows: {len(rows)}")
        lines.append("")
        lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
        lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
        for threshold in [0.2, 0.4, 0.6, 0.8, 0.9, 0.95]:
            metric = metric_at_threshold(rows, threshold)
            lines.append(
                "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                    **metric
                )
            )
        lines.append("")
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
