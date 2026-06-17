#!/usr/bin/env python3
"""Train an embedding + logistic-regression wake classifier."""

from __future__ import annotations

import argparse
import hashlib
import json
import pickle
from pathlib import Path
from typing import Any

import numpy as np
from sentence_transformers import SentenceTransformer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import classification_report, confusion_matrix
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import normalize


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "eval-sample.jsonl"
DEFAULT_LABELS = REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "embedding-baseline-report.md"
DEFAULT_MODEL = REPO / "feedback" / "intent-classifier" / "models" / "embedding-logreg-wake.pkl"
DEFAULT_CACHE_DIR = REPO / "feedback" / "intent-classifier" / "embedding-cache"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str, max_chars: int = 1600) -> str:
    return " ".join(str(text).split())[:max_chars]


def build_dataset(corpus_path: Path, labels_path: Path, min_confidence: float) -> tuple[list[dict[str, Any]], np.ndarray]:
    corpus = {row["id"]: row for row in read_jsonl(corpus_path)}
    rows: list[dict[str, Any]] = []
    y: list[int] = []
    for label in read_jsonl(labels_path):
        if label.get("error"):
            continue
        confidence = float(label.get("confidence") or 0)
        if confidence < min_confidence:
            continue
        record = corpus.get(label.get("record_id"))
        if not record:
            continue
        merged = dict(record)
        merged.update(label)
        rows.append(merged)
        y.append(int(bool(label.get("should_wake"))))
    return rows, np.array(y, dtype=np.int64)


def cache_key(model_id: str, rows: list[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    digest.update(model_id.encode())
    for row in rows:
        digest.update(str(row.get("id")).encode())
        digest.update(str(row.get("text_hash")).encode())
    return digest.hexdigest()[:16]


def embeddings_for(model_id: str, rows: list[dict[str, Any]], cache_dir: Path, batch_size: int, device: str) -> np.ndarray:
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache_path = cache_dir / f"{model_id.replace('/', '__')}-{cache_key(model_id, rows)}.npz"
    if cache_path.exists():
        return np.load(cache_path)["embeddings"]
    texts = [compact_text(row.get("text", "")) for row in rows]
    model = SentenceTransformer(model_id, trust_remote_code=True, device=device)
    embeddings = model.encode(
        texts,
        batch_size=batch_size,
        show_progress_bar=True,
        convert_to_numpy=True,
        normalize_embeddings=True,
    )
    embeddings = normalize(embeddings)
    np.savez_compressed(cache_path, embeddings=embeddings)
    return embeddings


def threshold_table(y_true: np.ndarray, scores: np.ndarray) -> list[dict[str, float]]:
    rows: list[dict[str, float]] = []
    for threshold in [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]:
        pred = scores >= threshold
        tp = int(((pred == 1) & (y_true == 1)).sum())
        fp = int(((pred == 1) & (y_true == 0)).sum())
        fn = int(((pred == 0) & (y_true == 1)).sum())
        tn = int(((pred == 0) & (y_true == 0)).sum())
        precision = tp / (tp + fp) if tp + fp else 0.0
        recall = tp / (tp + fn) if tp + fn else 0.0
        wake_rate = (tp + fp) / len(y_true) if len(y_true) else 0.0
        rows.append(
            {
                "threshold": threshold,
                "precision": precision,
                "recall": recall,
                "wake_rate": wake_rate,
                "tp": tp,
                "fp": fp,
                "fn": fn,
                "tn": tn,
            }
        )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--labels", type=Path, default=DEFAULT_LABELS)
    parser.add_argument("--model-id", default="sentence-transformers/all-MiniLM-L6-v2")
    parser.add_argument("--model-output", type=Path, default=DEFAULT_MODEL)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--cache-dir", type=Path, default=DEFAULT_CACHE_DIR)
    parser.add_argument("--min-confidence", type=float, default=0.65)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--device", default="cpu")
    args = parser.parse_args()

    rows, y = build_dataset(args.corpus, args.labels, args.min_confidence)
    if len(set(y.tolist())) < 2:
        raise SystemExit(f"Need both classes after filtering; rows={len(rows)} positives={int(y.sum())}")

    x = embeddings_for(args.model_id, rows, args.cache_dir, args.batch_size, args.device)
    indices = np.arange(len(rows))
    train_idx, test_idx, y_train, y_test = train_test_split(
        indices,
        y,
        test_size=0.25,
        random_state=42,
        stratify=y,
    )
    clf = LogisticRegression(
        max_iter=3000,
        class_weight="balanced",
        solver="liblinear",
        random_state=42,
    )
    clf.fit(x[train_idx], y_train)
    scores = clf.predict_proba(x[test_idx])[:, 1]
    predictions = (scores >= 0.5).astype(np.int64)

    args.model_output.parent.mkdir(parents=True, exist_ok=True)
    with args.model_output.open("wb") as handle:
        pickle.dump({"model_id": args.model_id, "classifier": clf}, handle)

    lines = ["# Embedding Intent Baseline Report", ""]
    lines.append(f"Embedding model: {args.model_id}")
    lines.append(f"Rows used: {len(rows)}")
    lines.append(f"Train rows: {len(train_idx)}")
    lines.append(f"Test rows: {len(test_idx)}")
    lines.append(f"Positive wake labels: {int(y.sum())}")
    lines.append("")
    lines.append("## Thresholds")
    lines.append("")
    lines.append("| threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in threshold_table(y_test, scores):
        lines.append(
            "| {threshold:.2f} | {precision:.2f} | {recall:.2f} | {wake_rate:.2f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    lines.append("")
    lines.append("## Classification Report At 0.50")
    lines.append("")
    lines.append("```text")
    lines.append(classification_report(y_test, predictions, target_names=["no_wake", "wake"], digits=3))
    lines.append("```")
    lines.append("")
    lines.append("## Confusion Matrix At 0.50")
    lines.append("")
    lines.append("```text")
    lines.append(str(confusion_matrix(y_test, predictions)))
    lines.append("```")

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
