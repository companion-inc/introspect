#!/usr/bin/env python3
"""Score exported Introspect samples with Hugging Face candidate models."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path
from typing import Any

import torch
from transformers import pipeline


REPO = Path(__file__).resolve().parents[2]
DEFAULT_SAMPLE = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "candidate-scores.jsonl"

TEXT_CLASSIFIERS = {
    "twitter_sentiment": "cardiffnlp/twitter-roberta-base-sentiment-latest",
    "go_emotions": "SamLowe/roberta-base-go_emotions",
    "emotion_distilroberta": "j-hartmann/emotion-english-distilroberta-base",
    "toxic_bert": "unitary/toxic-bert",
    "toxic_distilbert": "martin-ha/toxic-comment-model",
    "generic_intent": "Falconsai/intent_classification",
}

ZERO_SHOT = {
    "bart_mnli": "facebook/bart-large-mnli",
}

ZERO_SHOT_LABELS = [
    "agent behavior failure",
    "normal software task request",
    "external system complaint",
    "quoted log or transcript",
    "casual emotional language",
    "product or UI feedback",
    "request to continue previous work",
]


def read_jsonl(path: Path, limit: int) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with path.open() as handle:
        for raw in handle:
            row = json.loads(raw)
            rows.append(row)
    rows = balanced_order(rows)
    if limit:
        rows = rows[:limit]
    return rows


def balanced_order(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    buckets: dict[str, list[dict[str, Any]]] = {}
    for row in rows:
        buckets.setdefault(str(row.get("weak_label") or "unknown"), []).append(row)
    for bucket_rows in buckets.values():
        bucket_rows.sort(key=lambda row: hashlib.sha256(str(row.get("id") or row.get("text_hash") or row.get("text")).encode()).hexdigest())

    ordered: list[dict[str, Any]] = []
    labels = sorted(buckets)
    while any(buckets.values()):
        for label in labels:
            if buckets[label]:
                ordered.append(buckets[label].pop(0))
    return ordered


def compact_text(text: str, max_chars: int = 700) -> str:
    text = " ".join(text.split())
    return text[:max_chars]


def device() -> str | int:
    if torch.cuda.is_available():
        return 0
    if torch.backends.mps.is_available():
        return "mps"
    return -1


def score_text_classifier(name: str, model: str, rows: list[dict[str, Any]], out) -> None:
    classifier = pipeline(
        "text-classification",
        model=model,
        device=device(),
        top_k=None,
        truncation=True,
    )
    started = time.time()
    texts = [compact_text(row["text"]) for row in rows]
    results = classifier(texts, batch_size=32, truncation=True)
    for row, result in zip(rows, results):
        out.write(
            json.dumps(
                {
                    "record_id": row["id"],
                    "model_name": name,
                    "model_id": model,
                    "task": "text-classification",
                    "weak_label": row["weak_label"],
                    "old_trigger": row["old_trigger"],
                    "scores": result if isinstance(result, list) else [result],
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    elapsed = time.time() - started
    print(f"{name}: scored {len(rows)} rows in {elapsed:.1f}s")


def score_zero_shot(name: str, model: str, rows: list[dict[str, Any]], out) -> None:
    classifier = pipeline(
        "zero-shot-classification",
        model=model,
        device=device(),
        truncation=True,
    )
    started = time.time()
    for row in rows:
        result = classifier(compact_text(row["text"], 500), ZERO_SHOT_LABELS, multi_label=True)
        out.write(
            json.dumps(
                {
                    "record_id": row["id"],
                    "model_name": name,
                    "model_id": model,
                    "task": "zero-shot-classification",
                    "weak_label": row["weak_label"],
                    "old_trigger": row["old_trigger"],
                    "scores": [
                        {"label": label, "score": score}
                        for label, score in zip(result.get("labels", []), result.get("scores", []))
                    ],
                },
                ensure_ascii=False,
            )
            + "\n"
        )
    elapsed = time.time() - started
    print(f"{name}: scored {len(rows)} rows in {elapsed:.1f}s")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sample", type=Path, default=DEFAULT_SAMPLE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--limit", type=int, default=120)
    parser.add_argument(
        "--models",
        nargs="*",
        default=["twitter_sentiment", "go_emotions", "emotion_distilroberta", "toxic_bert", "toxic_distilbert", "generic_intent"],
    )
    args = parser.parse_args()

    rows = read_jsonl(args.sample, args.limit)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("w") as out:
        for name in args.models:
            if name in TEXT_CLASSIFIERS:
                score_text_classifier(name, TEXT_CLASSIFIERS[name], rows, out)
            elif name in ZERO_SHOT:
                score_zero_shot(name, ZERO_SHOT[name], rows, out)
            else:
                raise SystemExit(f"Unknown model name: {name}")


if __name__ == "__main__":
    main()
