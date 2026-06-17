#!/usr/bin/env python3
"""Pure-Python scorer for Introspect wake intent models."""

from __future__ import annotations

import json
import math
import os
import re
import unicodedata
from collections import Counter
from functools import lru_cache
from pathlib import Path
from typing import Any


DEFAULT_MODEL_PATH = Path(
    os.path.expanduser(
        os.environ.get("INTROSPECT_WAKE_MODEL", "~/.introspect/models/wake-logreg-v2-round4.json")
    )
)
TOKEN_RE = re.compile(r"(?u)\b\w\w+\b")


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def strip_accents(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    return "".join(char for char in normalized if not unicodedata.combining(char))


def classifier_text(
    prompt: str,
    *,
    source: str = "unknown",
    old_trigger: bool = False,
    matched_words: list[str] | None = None,
    prefix_fields: list[str] | None = None,
) -> str:
    fields = prefix_fields if prefix_fields is not None else ["source", "old_trigger", "matched_words"]
    prefix: list[str] = []
    if "source" in fields:
        prefix.append(f"source={source or 'unknown'}")
    if "old_trigger" in fields:
        prefix.append(f"old_trigger={bool(old_trigger)}")
    if "matched_words" in fields and matched_words:
        prefix.append("matched=" + ",".join(sorted(map(str, matched_words))))
    body = compact_text(prompt)
    if not prefix:
        return body
    return " ".join(prefix) + "\n" + body


def word_ngrams(text: str, ngram_range: list[int], strip: str | None, lowercase: bool) -> Counter[str]:
    if lowercase:
        text = text.lower()
    if strip == "unicode":
        text = strip_accents(text)
    tokens = TOKEN_RE.findall(text)
    counts: Counter[str] = Counter()
    min_n, max_n = ngram_range
    for n in range(min_n, max_n + 1):
        if len(tokens) < n:
            continue
        for index in range(0, len(tokens) - n + 1):
            counts[" ".join(tokens[index:index + n])] += 1
    return counts


def char_wb_ngrams(text: str, ngram_range: list[int], lowercase: bool) -> Counter[str]:
    if lowercase:
        text = text.lower()
    counts: Counter[str] = Counter()
    min_n, max_n = ngram_range
    for word in re.findall(r"\S+", text):
        padded = f" {word} "
        for n in range(min_n, max_n + 1):
            if len(padded) < n:
                continue
            for index in range(0, len(padded) - n + 1):
                counts[padded[index:index + n]] += 1
    return counts


@lru_cache(maxsize=4)
def load_model(path: str | os.PathLike[str] = DEFAULT_MODEL_PATH) -> dict[str, Any]:
    with Path(path).expanduser().open() as handle:
        model = json.load(handle)
    for section in ("word", "char_wb"):
        model[section]["feature_map"] = {
            term: (float(idf), float(coef))
            for term, idf, coef in model[section].get("features", [])
        }
    return model


def section_score(counts: Counter[str], feature_map: dict[str, tuple[float, float]], sublinear_tf: bool) -> float:
    weighted: list[tuple[float, float]] = []
    norm_sq = 0.0
    for term, count in counts.items():
        feature = feature_map.get(term)
        if not feature:
            continue
        idf, coef = feature
        tf = 1.0 + math.log(count) if sublinear_tf else float(count)
        value = tf * idf
        weighted.append((value, coef))
        norm_sq += value * value
    if norm_sq <= 0:
        return 0.0
    norm = math.sqrt(norm_sq)
    return sum((value / norm) * coef for value, coef in weighted)


def sigmoid(value: float) -> float:
    if value >= 0:
        z = math.exp(-value)
        return 1 / (1 + z)
    z = math.exp(value)
    return z / (1 + z)


def score_text(text: str, model: dict[str, Any] | None = None) -> dict[str, Any]:
    model = model or load_model()
    word_config = model["word"]
    char_config = model["char_wb"]
    score = float(model.get("intercept", 0.0))
    score += section_score(
        word_ngrams(
            text,
            word_config["ngram_range"],
            word_config.get("strip_accents"),
            bool(word_config.get("lowercase", True)),
        ),
        word_config["feature_map"],
        bool(word_config.get("sublinear_tf", True)),
    )
    score += section_score(
        char_wb_ngrams(
            text,
            char_config["ngram_range"],
            bool(char_config.get("lowercase", True)),
        ),
        char_config["feature_map"],
        bool(char_config.get("sublinear_tf", True)),
    )
    probability = sigmoid(score)
    threshold = float(model.get("threshold", 0.5))
    review_threshold = float(os.environ.get("INTROSPECT_WAKE_REVIEW_THRESHOLD", "0.30"))
    return {
        "score": probability,
        "threshold": threshold,
        "review_threshold": review_threshold,
        "triggered": probability >= threshold,
        "review": probability >= review_threshold,
        "model_type": model.get("model_type", "unknown"),
    }


def score_prompt(prompt: str, *, source: str = "unknown", old_trigger: bool = False, matched_words: list[str] | None = None) -> dict[str, Any]:
    model = load_model()
    prefix_fields = model.get("text_prefix_fields")
    text = classifier_text(
        prompt,
        source=source,
        old_trigger=old_trigger,
        matched_words=matched_words,
        prefix_fields=prefix_fields if isinstance(prefix_fields, list) else None,
    )
    return score_text(text, model)
