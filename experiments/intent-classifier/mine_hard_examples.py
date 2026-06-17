#!/usr/bin/env python3
"""Mine hard examples for the Introspect wake classifier."""

from __future__ import annotations

import argparse
import json
import pickle
import random
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.calibration import CalibratedClassifierCV
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import FeatureUnion, Pipeline
from sklearn.preprocessing import FunctionTransformer
from sklearn.svm import LinearSVC


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_AUDIT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_QWEN_LABELS = [
    REPO / "feedback" / "intent-classifier" / "qwen-labels.jsonl",
    REPO / "feedback" / "intent-classifier" / "qwen-labels-full.jsonl",
]
DEFAULT_OUTPUT_DIR = REPO / "feedback" / "intent-classifier" / "subagent-inputs-round3"
DEFAULT_SCORES = REPO / "feedback" / "intent-classifier" / "audit-model-scores.jsonl"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def text_features(rows: list[dict[str, Any]]) -> list[str]:
    texts: list[str] = []
    for row in rows:
        prefix = [
            f"source={row.get('source') or 'unknown'}",
            f"old_trigger={bool(row.get('old_trigger'))}",
        ]
        matched = row.get("matched_words") or row.get("old_matched_words") or []
        if matched:
            prefix.append("matched=" + ",".join(sorted(map(str, matched))))
        texts.append(" ".join(prefix) + "\n" + compact_text(row.get("text", "")))
    return texts


def audit_votes(path: Path) -> dict[str, dict[str, Any]]:
    votes: dict[str, list[dict[str, Any]]] = {}
    for label_file in sorted(path.glob("*.jsonl")):
        for row in read_jsonl(label_file):
            record_id = row.get("record_id")
            if record_id:
                votes.setdefault(str(record_id), []).append(row)
    resolved: dict[str, dict[str, Any]] = {}
    for record_id, rows in votes.items():
        counts = Counter(bool(row.get("should_wake")) for row in rows)
        resolved[record_id] = {
            "record_id": record_id,
            "should_wake": counts[True] >= counts[False],
            "votes": len(rows),
            "true_votes": counts[True],
            "false_votes": counts[False],
        }
    return resolved


def qwen_by_id(paths: list[Path]) -> dict[str, dict[str, Any]]:
    labels: dict[str, dict[str, Any]] = {}
    for path in paths:
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if record_id and not row.get("error"):
                labels[str(record_id)] = row
    return labels


def vectorizer() -> FeatureUnion:
    return FeatureUnion(
        [
            (
                "word",
                TfidfVectorizer(
                    analyzer="word",
                    ngram_range=(1, 4),
                    min_df=1,
                    max_features=90000,
                    strip_accents="unicode",
                    lowercase=True,
                    sublinear_tf=True,
                ),
            ),
            (
                "char",
                TfidfVectorizer(
                    analyzer="char_wb",
                    ngram_range=(3, 6),
                    min_df=1,
                    max_features=90000,
                    lowercase=True,
                    sublinear_tf=True,
                ),
            ),
        ]
    )


def make_logreg() -> Pipeline:
    return Pipeline(
        [
            ("text", FunctionTransformer(text_features, validate=False)),
            ("features", vectorizer()),
            (
                "clf",
                LogisticRegression(
                    max_iter=5000,
                    class_weight="balanced",
                    solver="liblinear",
                    C=1.0,
                    random_state=42,
                ),
            ),
        ]
    )


def make_svc() -> Pipeline:
    return Pipeline(
        [
            ("text", FunctionTransformer(text_features, validate=False)),
            ("features", vectorizer()),
            (
                "clf",
                CalibratedClassifierCV(
                    LinearSVC(class_weight="balanced", C=0.5, random_state=42),
                    cv=3,
                    method="sigmoid",
                ),
            ),
        ]
    )


def payload(row: dict[str, Any], score: float, qwen: dict[str, Any] | None) -> dict[str, Any]:
    return {
        "record_id": row["id"],
        "source": row.get("source"),
        "locator": row.get("locator"),
        "old_trigger": row.get("old_trigger"),
        "old_matched_words": row.get("matched_words", []),
        "audit_model_score": round(score, 6),
        "qwen_should_wake": qwen.get("should_wake") if qwen else None,
        "qwen_wake_label": qwen.get("wake_label") if qwen else None,
        "qwen_route_label": qwen.get("route_label") if qwen else None,
        "text": row.get("text", ""),
    }


def write_pack(path: Path, rows: list[dict[str, Any]], scores: dict[str, float], qwen: dict[str, dict[str, Any]], limit: int) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    rows = rows[:limit]
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(payload(row, scores[row["id"]], qwen.get(row["id"])), ensure_ascii=False) + "\n")
    return len(rows)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--qwen-labels", type=Path, nargs="*", default=DEFAULT_QWEN_LABELS)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--scores-output", type=Path, default=DEFAULT_SCORES)
    parser.add_argument("--limit", type=int, default=140)
    parser.add_argument("--seed", type=int, default=20260616)
    args = parser.parse_args()

    random.seed(args.seed)
    corpus = read_jsonl(args.corpus)
    corpus_by_id = {str(row["id"]): row for row in corpus}
    audit = audit_votes(args.audit_dir)
    qwen = qwen_by_id(args.qwen_labels)

    train_rows: list[dict[str, Any]] = []
    y: list[int] = []
    for record_id, label in audit.items():
        row = corpus_by_id.get(record_id)
        if row:
            train_rows.append(row)
            y.append(int(bool(label["should_wake"])))
    y_array = np.array(y, dtype=np.int64)
    logreg = make_logreg()
    svc = make_svc()
    logreg.fit(train_rows, y_array)
    svc.fit(train_rows, y_array)

    logreg_scores = logreg.predict_proba(corpus)[:, 1]
    svc_scores = svc.predict_proba(corpus)[:, 1]
    scores = (logreg_scores + svc_scores) / 2
    score_by_id = {str(row["id"]): float(score) for row, score in zip(corpus, scores)}

    args.scores_output.parent.mkdir(parents=True, exist_ok=True)
    with args.scores_output.open("w") as handle:
        for row, logreg_score, svc_score, score in zip(corpus, logreg_scores, svc_scores, scores):
            qwen_row = qwen.get(str(row["id"]))
            handle.write(
                json.dumps(
                    {
                        "record_id": row["id"],
                        "score": round(float(score), 6),
                        "logreg_score": round(float(logreg_score), 6),
                        "svc_score": round(float(svc_score), 6),
                        "old_trigger": bool(row.get("old_trigger")),
                        "qwen_should_wake": qwen_row.get("should_wake") if qwen_row else None,
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )

    audited_ids = set(audit)
    pool = [row for row in corpus if str(row["id"]) not in audited_ids]
    old_trigger_high = sorted(
        [row for row in pool if row.get("old_trigger") and score_by_id[str(row["id"])] >= 0.45],
        key=lambda row: score_by_id[str(row["id"])],
        reverse=True,
    )
    qwen_high_model_low = sorted(
        [
            row for row in pool
            if qwen.get(str(row["id"]), {}).get("should_wake") is True and score_by_id[str(row["id"])] <= 0.35
        ],
        key=lambda row: score_by_id[str(row["id"])],
    )
    model_high_old_false = sorted(
        [
            row for row in pool
            if not row.get("old_trigger") and score_by_id[str(row["id"])] >= 0.50
        ],
        key=lambda row: score_by_id[str(row["id"])],
        reverse=True,
    )
    boundary = [
        row for row in pool
        if 0.35 <= score_by_id[str(row["id"])] <= 0.50
    ]
    random.shuffle(boundary)
    random_pool = pool[:]
    random.shuffle(random_pool)

    summary = {
        "agent_i_model_high_old_trigger_round3.jsonl": write_pack(
            args.output_dir / "agent_i_model_high_old_trigger_round3.jsonl",
            old_trigger_high,
            score_by_id,
            qwen,
            args.limit,
        ),
        "agent_j_qwen_high_model_low_round3.jsonl": write_pack(
            args.output_dir / "agent_j_qwen_high_model_low_round3.jsonl",
            qwen_high_model_low,
            score_by_id,
            qwen,
            args.limit,
        ),
        "agent_k_model_high_old_false_round3.jsonl": write_pack(
            args.output_dir / "agent_k_model_high_old_false_round3.jsonl",
            model_high_old_false,
            score_by_id,
            qwen,
            args.limit,
        ),
        "agent_l_boundary_round3.jsonl": write_pack(
            args.output_dir / "agent_l_boundary_round3.jsonl",
            boundary,
            score_by_id,
            qwen,
            args.limit,
        ),
        "agent_m_random_round3.jsonl": write_pack(
            args.output_dir / "agent_m_random_round3.jsonl",
            random_pool,
            score_by_id,
            qwen,
            args.limit,
        ),
    }
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
