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
WAKE_SENSITIVITY_THRESHOLDS = {
    "sensitive": 0.50,
    "quiet": 0.80,
}
WAKE_SENSITIVITY_VALUES = {"quiet", "balanced", "sensitive", "custom"}


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


@lru_cache(maxsize=16)
def load_model(path: str | os.PathLike[str] = DEFAULT_MODEL_PATH) -> dict[str, Any]:
    with Path(path).expanduser().open() as handle:
        model = json.load(handle)
    for section in ("word", "char_wb"):
        model[section]["feature_map"] = {
            term: (float(idf), float(coef))
            for term, idf, coef in model[section].get("features", [])
        }
    return model


def section_contributions(
    counts: Counter[str],
    feature_map: dict[str, tuple[float, float]],
    sublinear_tf: bool,
    kind: str,
) -> list[dict[str, Any]]:
    weighted: list[tuple[str, float, float]] = []
    norm_sq = 0.0
    for term, count in counts.items():
        feature = feature_map.get(term)
        if not feature:
            continue
        idf, coef = feature
        tf = 1.0 + math.log(count) if sublinear_tf else float(count)
        value = tf * idf
        weighted.append((term, value, coef))
        norm_sq += value * value
    if norm_sq <= 0:
        return []
    norm = math.sqrt(norm_sq)
    rows: list[dict[str, Any]] = []
    for term, value, coef in weighted:
        rows.append(
            {
                "kind": kind,
                "feature": compact_text(term),
                "contribution": (value / norm) * coef,
            }
        )
    return rows


def section_score(counts: Counter[str], feature_map: dict[str, tuple[float, float]], sublinear_tf: bool) -> float:
    return sum(
        row["contribution"]
        for row in section_contributions(counts, feature_map, sublinear_tf, "feature")
    )


def sigmoid(value: float) -> float:
    if value >= 0:
        z = math.exp(-value)
        return 1 / (1 + z)
    z = math.exp(value)
    return z / (1 + z)


def clamp_threshold(value: float) -> float:
    return max(0.01, min(0.99, value))


def wake_sensitivity() -> str:
    value = os.environ.get("INTROSPECT_WAKE_SENSITIVITY", "balanced")
    cleaned = compact_text(value).lower()
    return cleaned if cleaned in WAKE_SENSITIVITY_VALUES else "balanced"


def custom_wake_threshold() -> float | None:
    value = compact_text(os.environ.get("INTROSPECT_WAKE_THRESHOLD", ""))
    if not value:
        return None
    try:
        return clamp_threshold(float(value))
    except ValueError:
        return None


def effective_wake_threshold(model: dict[str, Any]) -> tuple[float, float, str]:
    base_threshold = clamp_threshold(float(model.get("threshold", 0.5)))
    sensitivity = wake_sensitivity()
    if sensitivity == "custom":
        return custom_wake_threshold() or base_threshold, base_threshold, sensitivity
    override = WAKE_SENSITIVITY_THRESHOLDS.get(sensitivity)
    if override is None:
        return base_threshold, base_threshold, sensitivity
    return clamp_threshold(override), base_threshold, sensitivity


def score_text(text: str, model: dict[str, Any] | None = None) -> dict[str, Any]:
    model = model or load_model()
    word_config = model["word"]
    char_config = model["char_wb"]
    word_counts = word_ngrams(
        text,
        word_config["ngram_range"],
        word_config.get("strip_accents"),
        bool(word_config.get("lowercase", True)),
    )
    char_counts = char_wb_ngrams(
        text,
        char_config["ngram_range"],
        bool(char_config.get("lowercase", True)),
    )
    contributions = section_contributions(
        word_counts,
        word_config["feature_map"],
        bool(word_config.get("sublinear_tf", True)),
        "word",
    )
    contributions.extend(
        section_contributions(
            char_counts,
            char_config["feature_map"],
            bool(char_config.get("sublinear_tf", True)),
            "char",
        )
    )
    score = float(model.get("intercept", 0.0)) + sum(row["contribution"] for row in contributions)
    probability = sigmoid(score)
    threshold, base_threshold, sensitivity = effective_wake_threshold(model)
    review_threshold = float(os.environ.get("INTROSPECT_WAKE_REVIEW_THRESHOLD", "0.30"))
    explanations = sorted(
        (row for row in contributions if row["contribution"] > 0),
        key=lambda row: row["contribution"],
        reverse=True,
    )[:8]
    return {
        "score": probability,
        "threshold": threshold,
        "base_threshold": base_threshold,
        "wake_sensitivity": sensitivity,
        "review_threshold": review_threshold,
        "triggered": probability >= threshold,
        "review": probability >= review_threshold,
        "model_type": model.get("model_type", "unknown"),
        "explanations": explanations,
    }


def score_prompt_with_model(
    prompt: str,
    model: dict[str, Any],
    *,
    source: str = "unknown",
    old_trigger: bool = False,
    matched_words: list[str] | None = None,
) -> dict[str, Any]:
    prefix_fields = model.get("text_prefix_fields")
    text = classifier_text(
        prompt,
        source=source,
        old_trigger=old_trigger,
        matched_words=matched_words,
        prefix_fields=prefix_fields if isinstance(prefix_fields, list) else None,
    )
    return score_text(text, model)


def shadow_model_specs(raw: str | None = None) -> list[tuple[str, Path]]:
    value = os.environ.get("INTROSPECT_WAKE_SHADOW_MODELS", "") if raw is None else raw
    specs: list[tuple[str, Path]] = []
    for item in value.split(","):
        item = item.strip()
        if not item:
            continue
        if "=" in item:
            name, path = item.split("=", 1)
        else:
            path = item
            name = Path(path).stem
        name = compact_text(name)[:64] or Path(path).stem[:64] or "candidate"
        specs.append((name, Path(os.path.expanduser(path))))
    return specs


def score_shadow_models(
    prompt: str,
    *,
    source: str = "unknown",
    old_trigger: bool = False,
    matched_words: list[str] | None = None,
) -> list[dict[str, Any]]:
    alternates: list[dict[str, Any]] = []
    for name, path in shadow_model_specs():
        try:
            model = load_model(str(path))
            scored = score_prompt_with_model(
                prompt,
                model,
                source=source,
                old_trigger=old_trigger,
                matched_words=matched_words,
            )
            alternates.append(
                {
                    "name": name,
                    "score": scored["score"],
                    "threshold": scored["threshold"],
                    "review_threshold": scored["review_threshold"],
                    "triggered": scored["triggered"],
                    "review": scored["review"],
                    "model_type": scored["model_type"],
                }
            )
        except Exception as exc:
            alternates.append(
                {
                    "name": name,
                    "error": f"{type(exc).__name__}: {str(exc)[:160]}",
                }
            )
    return alternates


def score_prompt(
    prompt: str,
    *,
    source: str = "unknown",
    old_trigger: bool = False,
    matched_words: list[str] | None = None,
) -> dict[str, Any]:
    model = load_model()
    result = score_prompt_with_model(
        prompt,
        model,
        source=source,
        old_trigger=old_trigger,
        matched_words=matched_words,
    )
    alternates = score_shadow_models(
        prompt,
        source=source,
        old_trigger=old_trigger,
        matched_words=matched_words,
    )
    if alternates:
        result["alternates"] = alternates
    return result
