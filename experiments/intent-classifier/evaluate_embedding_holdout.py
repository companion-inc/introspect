#!/usr/bin/env python3
"""Evaluate embedding + logistic-regression wake classifiers with group holdout."""

from __future__ import annotations

import argparse
import hashlib
import json
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import normalize


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "embedding-group-holdout-report.md"
DEFAULT_CACHE = REPO / "feedback" / "intent-classifier" / "embedding-cache" / "nomic-gold-embeddings.npz"
DEFAULT_ENDPOINT = "http://127.0.0.1:8001/v1/embeddings"
DEFAULT_MODEL = "nomic-embed-text"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str, max_chars: int) -> str:
    return " ".join(str(text).split())[:max_chars]


def embed_text(row: dict[str, Any], max_chars: int, include_source: bool) -> str:
    text = compact_text(row.get("text", ""), max_chars)
    if include_source:
        return f"source={row.get('source') or 'unknown'}\n{text}"
    return text


def label_rows(audit_dir: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for path in sorted(audit_dir.glob("*.jsonl")):
        for row in read_jsonl(path):
            if row.get("record_id"):
                merged = dict(row)
                merged["label_file"] = path.name
                rows.append(merged)
    return rows


def resolved_training_labels(rows: list[dict[str, Any]]) -> dict[str, bool]:
    votes: dict[str, list[bool]] = {}
    for row in rows:
        votes.setdefault(str(row["record_id"]), []).append(bool(row.get("should_wake")))
    resolved: dict[str, bool] = {}
    for record_id, values in votes.items():
        counts = Counter(values)
        resolved[record_id] = counts[True] >= counts[False]
    return resolved


def cache_key(ids: list[str], texts: list[str], model: str) -> str:
    digest = hashlib.sha256(model.encode())
    for row_id, text in zip(ids, texts):
        digest.update(row_id.encode())
        digest.update(b"\0")
        digest.update(text.encode("utf-8", errors="ignore"))
    return digest.hexdigest()[:16]


def request_embeddings(endpoint: str, model: str, texts: list[str], timeout: int) -> np.ndarray:
    payload = {"model": model, "input": texts}
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    body = json.loads(urllib.request.urlopen(request, timeout=timeout).read().decode())
    ordered = sorted(body["data"], key=lambda item: item["index"])
    return np.array([item["embedding"] for item in ordered], dtype=np.float32)


def embeddings_for(
    rows: list[dict[str, Any]],
    cache_path: Path,
    endpoint: str,
    model: str,
    batch_size: int,
    max_chars: int,
    include_source: bool,
    timeout: int,
) -> tuple[list[str], np.ndarray]:
    ids = [str(row["id"]) for row in rows]
    texts = [embed_text(row, max_chars, include_source) for row in rows]
    key = cache_key(ids, texts, model)
    path = cache_path.with_name(f"{cache_path.stem}-{key}{cache_path.suffix}")
    if path.exists():
        data = np.load(path, allow_pickle=True)
        return list(data["ids"]), data["embeddings"]

    batches: list[np.ndarray] = []
    for start in range(0, len(texts), batch_size):
        batch = texts[start:start + batch_size]
        batches.append(request_embeddings(endpoint, model, batch, timeout))
        print(json.dumps({"embedded": min(start + len(batch), len(texts)), "total": len(texts)}), flush=True)
    embeddings = normalize(np.vstack(batches))
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez_compressed(path, ids=np.array(ids), embeddings=embeddings)
    return ids, embeddings


def metric_row(y_true: np.ndarray, scores: np.ndarray, threshold: float) -> dict[str, float | int]:
    pred = scores >= threshold
    tp = int(((pred == 1) & (y_true == 1)).sum())
    fp = int(((pred == 1) & (y_true == 0)).sum())
    fn = int(((pred == 0) & (y_true == 1)).sum())
    tn = int(((pred == 0) & (y_true == 0)).sum())
    return {
        "threshold": threshold,
        "precision": tp / (tp + fp) if tp + fp else 0.0,
        "recall": tp / (tp + fn) if tp + fn else 0.0,
        "wake_rate": (tp + fp) / len(y_true) if len(y_true) else 0.0,
        "tp": tp,
        "fp": fp,
        "fn": fn,
        "tn": tn,
    }


def threshold_grid() -> list[float]:
    return [round(value / 1000, 3) for value in range(200, 951, 5)]


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, precision_floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= precision_floor and int(row["tp"]) > 0]
    if not viable:
        return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"])))
    return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--max-chars", type=int, default=1600)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--c-values", default="0.25,0.5,1.0,2.0,4.0,8.0")
    parser.add_argument("--include-source", action="store_true")
    args = parser.parse_args()

    corpus = {str(row["id"]): row for row in read_jsonl(args.corpus)}
    labels = label_rows(args.audit_dir)
    groups = sorted({str(row["label_file"]) for row in labels})
    ids = sorted({str(row["record_id"]) for row in labels if str(row["record_id"]) in corpus})
    rows = [corpus[row_id] for row_id in ids]
    embed_ids, embeddings = embeddings_for(
        rows,
        args.cache,
        args.endpoint,
        args.model,
        args.batch_size,
        args.max_chars,
        args.include_source,
        args.timeout,
    )
    index_by_id = {str(row_id): index for index, row_id in enumerate(embed_ids)}

    c_values = [float(value) for value in args.c_values.split(",") if value]
    results: list[dict[str, Any]] = []
    for c_value in c_values:
        all_scores: list[float] = []
        all_truth: list[int] = []
        for group in groups:
            test_labels = [row for row in labels if row["label_file"] == group]
            test_ids = {str(row["record_id"]) for row in test_labels}
            train_labels = [row for row in labels if str(row["record_id"]) not in test_ids]
            train_resolved = resolved_training_labels(train_labels)
            train_indices: list[int] = []
            train_y: list[int] = []
            for record_id, should_wake in train_resolved.items():
                index = index_by_id.get(record_id)
                if index is not None:
                    train_indices.append(index)
                    train_y.append(int(should_wake))
            test_indices: list[int] = []
            test_y: list[int] = []
            for row in test_labels:
                index = index_by_id.get(str(row["record_id"]))
                if index is not None:
                    test_indices.append(index)
                    test_y.append(int(bool(row.get("should_wake"))))
            if len(set(train_y)) < 2 or not test_indices:
                continue
            clf = LogisticRegression(
                max_iter=3000,
                class_weight="balanced",
                solver="liblinear",
                C=c_value,
                random_state=42,
            )
            clf.fit(embeddings[train_indices], np.array(train_y, dtype=np.int64))
            scores = clf.predict_proba(embeddings[test_indices])[:, 1]
            all_scores.extend(map(float, scores))
            all_truth.extend(test_y)
        y_all = np.array(all_truth, dtype=np.int64)
        scores_all = np.array(all_scores, dtype=np.float64)
        selected = best_at_precision(y_all, scores_all, args.precision_floor)
        result = {"c_value": c_value, **selected}
        results.append(result)
        print(json.dumps(result, sort_keys=True), flush=True)

    ranked = sorted(
        results,
        key=lambda row: (
            float(row["precision"]) >= args.precision_floor,
            float(row["recall"]),
            float(row["precision"]),
            -float(row["wake_rate"]),
        ),
        reverse=True,
    )
    best = ranked[0]

    lines = ["# Embedding Group Holdout Report", ""]
    lines.append(f"Embedding model: {args.model}")
    lines.append(f"Gold unique rows: {len(ids)}")
    lines.append(f"Evaluated labels: {len(labels)}")
    lines.append(f"Precision floor: {args.precision_floor:.3f}")
    lines.append(f"Include source prefix: {args.include_source}")
    lines.append("")
    lines.append("## Best")
    lines.append("")
    lines.append("| C | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| {c_value:.2f} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **best
        )
    )
    lines.append("")
    lines.append("## All Candidates")
    lines.append("")
    lines.append("| C | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for row in ranked:
        lines.append(
            "| {c_value:.2f} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
                **row
            )
        )
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)


if __name__ == "__main__":
    main()
