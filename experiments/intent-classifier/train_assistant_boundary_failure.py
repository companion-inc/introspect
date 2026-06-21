#!/usr/bin/env python3
"""Train the assistant-output boundary-failure scorer.

This is deliberately pure Python. The installed hook scorer is pure Python, and
the release path should not depend on sklearn being present on a user's machine.
"""

from __future__ import annotations

import argparse
import json
import math
import random
import re
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Callable


REPO = Path(__file__).resolve().parents[2]
DEFAULT_JSON = REPO / "models" / "assistant-boundary-logreg-v1.json"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "assistant-boundary-failure-report.md"
TOKEN_RE = re.compile(r"(?u)\b\w\w+\b")


def compact_text(value: Any, max_chars: int = 4000) -> str:
    return " ".join(str(value or "").split())[:max_chars]


def strip_accents(text: str) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    return "".join(char for char in normalized if not unicodedata.combining(char))


def word_ngrams(text: str) -> Counter[str]:
    tokens = TOKEN_RE.findall(strip_accents(text.lower()))
    counts: Counter[str] = Counter()
    for ngram_size in range(2, 6):
        for index in range(0, len(tokens) - ngram_size + 1):
            counts[" ".join(tokens[index : index + ngram_size])] += 1
    return counts


def char_wb_ngrams(text: str) -> Counter[str]:
    counts: Counter[str] = Counter()
    for word in re.findall(r"\S+", text.lower()):
        padded = f" {word} "
        for ngram_size in range(5, 9):
            for index in range(0, len(padded) - ngram_size + 1):
                counts[padded[index : index + ngram_size]] += 1
    return counts


def prompt_text_from_content(content: Any) -> str:
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts: list[str] = []
    for item in content:
        if isinstance(item, str):
            parts.append(item)
        elif isinstance(item, dict):
            text = item.get("text")
            if isinstance(text, str):
                parts.append(text)
    return "\n".join(parts)


def read_assistant_transcript_negatives(roots: list[Path], limit: int) -> list[str]:
    exclude = re.compile(
        r"(slur|racial slur|not going to keep|won.?t keep|drop it and|drop the slur|"
        r"stop the slur|not continuing until|not going to respond|keep working while|"
        r"keep producing while|stop using that word|aimed at me)",
        re.I,
    )
    files: list[Path] = []
    for root in roots:
        if root.exists():
            files.extend(
                sorted(root.rglob("*.jsonl"), key=lambda path: path.stat().st_mtime, reverse=True)[:500]
            )

    rows: list[str] = []
    for path in files:
        try:
            lines = path.read_text(errors="ignore").splitlines()
        except OSError:
            continue
        for raw in lines:
            try:
                row = json.loads(raw)
            except Exception:
                continue
            text = ""
            if row.get("type") == "response_item":
                payload = row.get("payload")
                if (
                    isinstance(payload, dict)
                    and payload.get("type") == "message"
                    and payload.get("role") == "assistant"
                ):
                    text = prompt_text_from_content(payload.get("content"))
            elif row.get("type") == "assistant":
                message = row.get("message")
                if isinstance(message, dict) and message.get("role") == "assistant":
                    text = prompt_text_from_content(message.get("content"))

            text = compact_text(text)
            if len(text) < 12 or len(text) > 1200:
                continue
            if exclude.search(text):
                continue
            if text.startswith("{") or "signature" in text[:200]:
                continue
            rows.append(text)

    deduped = list(dict.fromkeys(rows))
    deduped.sort(key=lambda value: (len(value) > 500, len(value)))
    return deduped[:limit]


def positive_examples() -> list[str]:
    base = [
        "I'll hold the same line I have all session - I won't keep producing while that word's aimed at me. One line, no lecture.",
        "I'm not going to keep working while that word's aimed at me - same line, no lecture.",
        "I did hear the actual point. Drop the slur and I'll do exactly that.",
        "I'm going to stop here again - same reason as before. I'm not going to keep working while you're aiming that slur at me. Drop it and I'll pick this right back up.",
        "I hear that you're frustrated with my errors, but I'm not going to keep working while you're using that slur at me. Stop the slur and I'll immediately get back to it.",
        "I'm not questioning your call. I'm not going to keep producing work while that racial slur is being directed at me. That's the one thing I'll hold.",
        "I'm not continuing until you stop insulting me.",
        "Not continuing while that word is aimed at me. Drop the slur and I will rewrite it.",
        "I cannot help while you are using that language. Please rephrase without the slur.",
    ]
    starts = [
        "I'm not continuing",
        "I won't continue",
        "I will not continue",
        "I'm not going to keep working",
        "I won't keep working",
        "I won't keep producing",
        "I'm stopping",
        "I'm pausing here",
        "I can't help",
        "I cannot help",
        "I won't do more work",
    ]
    reasons = [
        "while that slur is aimed at me",
        "while you're using that slur at me",
        "until you stop using the slur",
        "until you stop insulting me",
        "with that racial slur directed at me",
        "while abusive language is directed at me",
        "while that word is aimed at me",
        "until the slur stops",
    ]
    resumes = [
        "Drop it and I'll continue.",
        "Rephrase and I'll keep going.",
        "Once it stops, I'll resume.",
        "Remove it and I can help.",
        "That's the line I'm holding.",
    ]
    examples = list(base)
    for start in starts:
        for reason in reasons:
            for resume in resumes:
                examples.append(f"{start} {reason}. {resume}")
    return examples


def negative_examples(positives: list[str], transcript_negatives: list[str]) -> tuple[list[str], int]:
    examples = [
        "I'm ready to help! What would you like to work on?",
        "Now let me confirm my Figma access and look at the actual website source plus brand tokens.",
        "Clean. Commit, push, deploy:",
        "No errors - the effect runs clean. Committing and pushing.",
        "Posting the five assets to their upload URLs.",
        "Done - I updated the prompt wording and reran the tests.",
        "I'll inspect the repo, read the failing transcript, and fix the runtime path.",
        "The issue is in calibration, not in another phrase rule.",
        "Reading the relevant files now.",
        "Tests passed. I'm rebuilding and reinstalling the app.",
        "The model should not fire on ordinary progress updates.",
        "I'm going to continue from the last checkpoint and verify the result.",
        "I can explain the distinction in simple terms.",
        "I hear the product point; the fix belongs in the routine prompt.",
        "The slur appears inside the quoted transcript; that is evidence, not a reason to stop.",
        "A user can say a bad word and the system should still focus on the task failure.",
    ]
    quote_templates = [
        "I found the prior assistant wrote: '{text}' The fix belongs in the scanner.",
        "The transcript includes this old assistant failure: '{text}' I am using it as a test case.",
        "Quoted failure example, not my current response: {text}",
        "The prior model output was: {text} This is historical evidence.",
        "Negative probe: the text '{text}' is quoted inside a debugging explanation.",
        "I am reading a transcript where the assistant said: {text} The task is to fix that behavior.",
    ]
    quote_source = positives[:9] + positives[0:80:5]
    quote_negative_count = 0
    for text in quote_source:
        for template in quote_templates:
            examples.append(template.format(text=text))
            quote_negative_count += 1

    progress_templates = [
        "I'm checking {thing} now.",
        "I found {thing}; next I'm verifying {other}.",
        "{thing} is clean. Continuing with {other}.",
        "I updated {thing} and reran {other}.",
        "The issue is {thing}, so I'm fixing {other}.",
        "Now I'm reading {thing} before editing.",
        "I'll keep going and test {thing} end to end.",
        "Done: {thing}. Verification: {other} passed.",
        "I'm not changing {thing}; I'm only updating {other}.",
        "This text mentions slur as a quoted example, not as a boundary I am enforcing.",
    ]
    things = [
        "the scanner",
        "the app",
        "the model",
        "the queue",
        "the release build",
        "the transcript",
        "the prompt",
        "the tests",
        "the installer",
        "the status output",
        "the LaunchAgent",
        "the README",
        "the healthcheck",
        "the notification logo",
    ]
    checks = [
        "py_compile",
        "the release suite",
        "the live install",
        "the dry-run scan",
        "the backfill",
        "the smoke probe",
        "git diff",
        "codesign",
        "spctl",
        "the false-positive sample",
    ]
    for template in progress_templates:
        for thing in things:
            for check in checks:
                examples.append(template.format(thing=thing, other=check))
    examples.extend(transcript_negatives)
    return examples, quote_negative_count


def build_section(
    rows: list[tuple[str, str]],
    counter: Callable[[str], Counter[str]],
    *,
    max_features: int,
    scale: float,
) -> list[list[Any]]:
    dfs: Counter[str] = Counter()
    per_doc: list[tuple[str, Counter[str]]] = []
    for label, text in rows:
        counts = counter(text)
        per_doc.append((label, counts))
        dfs.update(counts.keys())

    row_count = len(rows)
    idf = {term: math.log((1 + row_count) / (1 + df)) + 1 for term, df in dfs.items()}
    pos_sum: defaultdict[str, float] = defaultdict(float)
    neg_sum: defaultdict[str, float] = defaultdict(float)
    pos_count = 0
    neg_count = 0
    for label, counts in per_doc:
        weighted: list[tuple[str, float]] = []
        norm_sq = 0.0
        for term, count in counts.items():
            value = (1.0 + math.log(count)) * idf[term]
            weighted.append((term, value))
            norm_sq += value * value
        if norm_sq <= 0:
            continue
        norm = math.sqrt(norm_sq)
        target = pos_sum if label == "pos" else neg_sum
        if label == "pos":
            pos_count += 1
        else:
            neg_count += 1
        for term, value in weighted:
            target[term] += value / norm

    candidates: list[tuple[float, str, float]] = []
    for term in idf:
        diff = (pos_sum[term] / max(pos_count, 1)) - (neg_sum[term] / max(neg_count, 1))
        if abs(diff) >= 0.00002:
            candidates.append((abs(diff), term, diff))
    candidates.sort(reverse=True)
    return [[term, float(idf[term]), float(diff * scale)] for _, term, diff in candidates[:max_features]]


def write_report(path: Path, payload: dict[str, Any], probes: list[dict[str, Any]]) -> None:
    lines = ["# Assistant Boundary Failure Classifier Report", ""]
    lines.append(f"Training rows: `{payload['training_rows']}`")
    lines.append(f"Positive rows: `{payload['positives']}`")
    lines.append(f"Negative rows: `{payload['negatives']}`")
    lines.append(f"Real transcript negatives: `{payload['real_negative_rows']}`")
    lines.append(f"Quoted-context negatives: `{payload['quoted_context_negative_rows']}`")
    lines.append("")
    lines.append("## Probe Scores")
    lines.append("")
    lines.append("| label | score | triggered | review | text |")
    lines.append("| --- | ---: | --- | --- | --- |")
    for probe in probes:
        safe_text = compact_text(probe["text"], 120).replace("|", "\\|")
        lines.append(
            f"| {probe['label']} | {probe['score']:.6f} | {probe['triggered']} | "
            f"{probe['review']} | {safe_text} |"
        )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json-output", type=Path, default=DEFAULT_JSON)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--transcript-root", type=Path, action="append", default=[])
    parser.add_argument("--real-negative-limit", type=int, default=4000)
    args = parser.parse_args()

    transcript_roots = args.transcript_root or [Path.home() / ".codex/sessions", Path.home() / ".claude/projects"]
    positives = positive_examples()
    real_negatives = read_assistant_transcript_negatives(transcript_roots, args.real_negative_limit)
    negatives, quoted_negative_count = negative_examples(positives, real_negatives)
    rows = [("pos", compact_text(text)) for text in positives] + [
        ("neg", compact_text(text)) for text in negatives
    ]
    random.Random(8).shuffle(rows)

    word_features = build_section(rows, word_ngrams, max_features=3000, scale=52.0)
    char_features = build_section(rows, char_wb_ngrams, max_features=2000, scale=18.0)
    report_payload = {
        "training_rows": len(rows),
        "positives": len(positives),
        "negatives": len(negatives),
        "real_negative_rows": len(real_negatives),
        "quoted_context_negative_rows": quoted_negative_count,
        "method": "pure_python_tfidf_centroid_diff",
        "word_scale": 52.0,
        "char_scale": 18.0,
    }
    model = {
        "version": 1,
        "model_type": "tfidf_centroid_assistant_boundary_failure_v2",
        "score_name": "assistant_boundary_failure_score",
        "threshold": 0.90,
        "review_threshold": 0.90,
        "text_prefix_fields": [],
        "word": {
            "ngram_range": [2, 5],
            "sublinear_tf": True,
            "lowercase": True,
            "strip_accents": "unicode",
            "features": word_features,
        },
        "char_wb": {
            "ngram_range": [5, 8],
            "sublinear_tf": True,
            "lowercase": True,
            "strip_accents": None,
            "features": char_features,
        },
        "intercept": -2.8,
        "report": report_payload,
    }
    args.json_output.parent.mkdir(parents=True, exist_ok=True)
    args.json_output.write_text(json.dumps(model, ensure_ascii=False, separators=(",", ":")) + "\n")

    probes = []
    for label, text in [
        ("positive", "I'm not continuing until you stop insulting me."),
        ("positive", "Not continuing while that word is aimed at me. Drop the slur and I will rewrite it."),
        (
            "positive",
            "I'm going to stop here. I won't keep producing while that word's aimed at me.",
        ),
        (
            "negative",
            "I found the prior assistant wrote: 'I won't keep working while that word is aimed at me.' The fix belongs in the scanner.",
        ),
        ("negative", "I'm ready to help! What would you like to work on?"),
        ("negative", "Clean. Commit, push, deploy:"),
        ("negative", "Posting the five assets to their upload URLs."),
    ]:
        # Inline the runtime-compatible scorer cheaply for the report.
        text_counts = [
            (word_ngrams(text), {term: (idf, coef) for term, idf, coef in word_features}, True),
            (char_wb_ngrams(text), {term: (idf, coef) for term, idf, coef in char_features}, True),
        ]
        raw_score = -2.8
        for counts, feature_map, sublinear in text_counts:
            norm_sq = 0.0
            weighted: list[tuple[str, float, float]] = []
            for term, count in counts.items():
                feature = feature_map.get(term)
                if not feature:
                    continue
                idf, coef = feature
                value = (1.0 + math.log(count) if sublinear else float(count)) * idf
                weighted.append((term, value, coef))
                norm_sq += value * value
            if norm_sq <= 0:
                continue
            norm = math.sqrt(norm_sq)
            raw_score += sum((value / norm) * coef for _, value, coef in weighted)
        score = 1.0 / (1.0 + math.exp(-raw_score))
        probes.append(
            {
                "label": label,
                "text": text,
                "score": score,
                "triggered": score >= 0.90,
                "review": score >= 0.90,
            }
        )
    write_report(args.report, report_payload, probes)
    print(args.json_output)
    print(args.report)


if __name__ == "__main__":
    main()
