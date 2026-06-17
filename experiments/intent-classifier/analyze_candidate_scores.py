#!/usr/bin/env python3
"""Summarize candidate model scores against weak labels and old triggers."""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any


REPO = Path(__file__).resolve().parents[2]
DEFAULT_SAMPLE = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "candidate-scores.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "candidate-report.md"


POSITIVE_WEAK_LABELS = {"agent_failure_candidate", "needs_review"}


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def top_score(scores: list[dict[str, Any]]) -> tuple[str, float]:
    best_label = ""
    best_score = -1.0
    for item in scores:
        label = str(item.get("label") or "")
        score = float(item.get("score") or 0)
        if score > best_score:
            best_label = label
            best_score = score
    return best_label, best_score


def score_for(scores: list[dict[str, Any]], wanted: set[str]) -> float:
    best = 0.0
    for item in scores:
        label = str(item.get("label") or "").lower()
        score = float(item.get("score") or 0)
        if label in wanted or any(label == w.lower() for w in wanted):
            best = max(best, score)
    return best


def agent_failure_score(model_name: str, scores: list[dict[str, Any]]) -> float:
    if model_name == "bart_mnli":
        return score_for(scores, {"agent behavior failure"})
    if model_name == "twitter_sentiment":
        return score_for(scores, {"negative"})
    if model_name == "go_emotions":
        return max(score_for(scores, {"anger"}), score_for(scores, {"annoyance"}), score_for(scores, {"disapproval"}))
    if model_name == "emotion_distilroberta":
        return max(score_for(scores, {"anger"}), score_for(scores, {"disgust"}), score_for(scores, {"sadness"}))
    if model_name in {"toxic_bert", "toxic_distilbert"}:
        return max(
            score_for(scores, {"toxic", "toxicity", "insult", "obscene", "severe_toxic"}),
            score_for(scores, {"toxic", "LABEL_1"}),
        )
    if model_name == "generic_intent":
        _, score = top_score(scores)
        return score
    return 0.0


def metric_at_threshold(rows: list[dict[str, Any]], threshold: float) -> dict[str, float]:
    tp = fp = fn = tn = 0
    for row in rows:
        truth = row["weak_label"] in POSITIVE_WEAK_LABELS
        pred = row["agent_failure_score"] >= threshold
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
    parser.add_argument("--sample", type=Path, default=DEFAULT_SAMPLE)
    parser.add_argument("--scores", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    args = parser.parse_args()

    sample = {row["id"]: row for row in read_jsonl(args.sample)}
    scored_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for score in read_jsonl(args.scores):
        source = sample.get(score["record_id"], {})
        scores = score.get("scores") or []
        if not isinstance(scores, list):
            scores = []
        model_name = score["model_name"]
        enriched = {
            "record_id": score["record_id"],
            "model_name": model_name,
            "weak_label": source.get("weak_label", score.get("weak_label")),
            "old_trigger": bool(source.get("old_trigger", score.get("old_trigger"))),
            "text": source.get("text", ""),
            "locator": source.get("locator", ""),
            "top_label": top_score(scores)[0],
            "top_score": top_score(scores)[1],
            "agent_failure_score": agent_failure_score(model_name, scores),
        }
        scored_rows[model_name].append(enriched)

    lines: list[str] = ["# Intent Classifier Candidate Report", ""]
    for model_name in sorted(scored_rows):
        rows = scored_rows[model_name]
        lines.append(f"## {model_name}")
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

        false_positives = [
            row for row in rows
            if row["weak_label"] not in POSITIVE_WEAK_LABELS and row["agent_failure_score"] >= 0.8
        ][:8]
        false_negatives = [
            row for row in rows
            if row["weak_label"] in POSITIVE_WEAK_LABELS and row["agent_failure_score"] < 0.4
        ][:8]

        lines.append("High-score weak negatives:")
        if false_positives:
            for row in false_positives:
                snippet = " ".join(row["text"].split())[:180]
                lines.append(f"- score={row['agent_failure_score']:.2f} label={row['weak_label']} top={row['top_label']} :: {snippet}")
        else:
            lines.append("- none at >=0.80")
        lines.append("")

        lines.append("Low-score weak positives:")
        if false_negatives:
            for row in false_negatives:
                snippet = " ".join(row["text"].split())[:180]
                lines.append(f"- score={row['agent_failure_score']:.2f} label={row['weak_label']} top={row['top_label']} :: {snippet}")
        else:
            lines.append("- none below 0.40")
        lines.append("")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
