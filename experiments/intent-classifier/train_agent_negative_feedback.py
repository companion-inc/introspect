#!/usr/bin/env python3
"""Train a compact agent-negative-feedback classifier.

The score trained here is the single product signal for both surfaces:
- thresholded wake/count events in Introspect
- continuous negative reward for later agent/RL work
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import ssl
import time
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import train_test_split

from train_intent_v2_grid import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    best_at_precision,
    config_name,
    export_model,
    fit_model,
    label_rows,
    load_corpora,
    make_model,
    metric_row,
    resolved_labels,
    scores_for,
)


REPO = Path(__file__).resolve().parents[2]
BASE_URL = "https://datasets-server.huggingface.co"
DEFAULT_PUBLIC_CACHE = REPO / "feedback" / "intent-classifier" / "agent-trace-sentiment-public.jsonl"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "agent-negative-feedback-report.md"
DEFAULT_JSON = REPO / "feedback" / "intent-classifier" / "agent-negative-feedback-logreg.json"
DEFAULT_DATASET = "davanstrien/agent-trace-sentiment"

try:
    import certifi  # type: ignore
except Exception:  # pragma: no cover - optional local cert bundle
    certifi = None

SSL_CONTEXT = ssl.create_default_context(cafile=certifi.where()) if certifi else ssl._create_unverified_context()


def compact_text(text: Any, max_chars: int = 4000) -> str:
    return " ".join(str(text or "").split())[:max_chars]


def get_json(url: str, timeout: int = 90) -> dict[str, Any]:
    request = urllib.request.Request(url, headers={"User-Agent": "introspect-agent-negative-feedback/1.0"})
    with urllib.request.urlopen(request, timeout=timeout, context=SSL_CONTEXT) as response:
        return json.loads(response.read().decode())


def viewer_url(path: str, params: dict[str, Any]) -> str:
    return f"{BASE_URL}/{path}?{urllib.parse.urlencode(params)}"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(raw) for raw in handle if raw.strip()]


def write_jsonl(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")


def retag_export(path: Path) -> None:
    obj = json.loads(path.read_text())
    obj["model_type"] = "tfidf_logreg_agent_negative_feedback_v1"
    obj["score_name"] = "agent_negative_feedback_score"
    path.write_text(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")


def public_splits(dataset: str) -> list[tuple[str, str]]:
    body = get_json(viewer_url("splits", {"dataset": dataset}))
    return [
        (str(row["config"]), str(row["split"]))
        for row in body.get("splits", [])
        if row.get("config") and row.get("split")
    ]


def fetch_public_rows(dataset: str, cache_path: Path, *, refresh: bool, page_size: int) -> list[dict[str, Any]]:
    if cache_path.exists() and not refresh:
        return read_jsonl(cache_path)

    try:
        rows = fetch_public_rows_from_parquet(dataset, cache_path)
        write_jsonl(cache_path, rows)
        return rows
    except Exception as exc:
        print(
            json.dumps(
                {
                    "dataset": dataset,
                    "parquet_fetch_error": f"{type(exc).__name__}: {str(exc)[:240]}",
                    "fallback": "dataset_viewer_rows",
                },
                sort_keys=True,
            ),
            flush=True,
        )

    rows: list[dict[str, Any]] = []
    for config, split in public_splits(dataset):
        offset = 0
        while True:
            body = get_json(
                viewer_url(
                    "rows",
                    {
                        "dataset": dataset,
                        "config": config,
                        "split": split,
                        "offset": offset,
                        "length": page_size,
                    },
                )
            )
            page = body.get("rows") or []
            if not page:
                break
            for item in page:
                row = item.get("row") or {}
                label = str(row.get("sentiment_label") or "").upper()
                if label not in {"NEGATIVE", "NEUTRAL", "POSITIVE"}:
                    continue
                text = compact_text(row.get("content_text"))
                if not text:
                    continue
                rows.append(
                    {
                        "id": f"hf:{dataset}:{config}:{split}:{item.get('row_idx', offset)}",
                        "source": f"hf_agent_trace_sentiment:{dataset}",
                        "dataset": dataset,
                        "config": config,
                        "split": split,
                        "row_idx": item.get("row_idx"),
                        "text": text,
                        "label": int(label == "NEGATIVE"),
                        "sentiment_label": label,
                        "agent": row.get("agent"),
                        "source_dataset": row.get("source_dataset"),
                        "n_errors": row.get("n_errors"),
                        "n_tool_calls": row.get("n_tool_calls"),
                    }
                )
            offset += len(page)
            print(json.dumps({"dataset": dataset, "config": config, "split": split, "fetched": len(rows)}), flush=True)
            if len(page) < page_size or body.get("partial"):
                break
            time.sleep(0.05)

    write_jsonl(cache_path, rows)
    return rows


def fetch_public_rows_from_parquet(dataset: str, cache_path: Path) -> list[dict[str, Any]]:
    import pyarrow.parquet as pq  # type: ignore

    body = get_json(viewer_url("parquet", {"dataset": dataset}))
    files = body.get("parquet_files") or []
    if not files:
        raise RuntimeError("Dataset Viewer parquet endpoint returned no parquet files")

    rows: list[dict[str, Any]] = []
    parquet_dir = cache_path.parent / "parquet-cache" / dataset.replace("/", "__")
    parquet_dir.mkdir(parents=True, exist_ok=True)
    for parquet_file in files:
        url = str(parquet_file["url"])
        local_path = parquet_dir / str(parquet_file.get("filename") or f"{len(rows)}.parquet")
        if not local_path.exists():
            request = urllib.request.Request(url, headers={"User-Agent": "introspect-agent-negative-feedback/1.0"})
            with urllib.request.urlopen(request, timeout=180, context=SSL_CONTEXT) as response:
                local_path.write_bytes(response.read())
        table = pq.read_table(local_path)
        for index, row in enumerate(table.to_pylist()):
            label = str(row.get("sentiment_label") or "").upper()
            if label not in {"NEGATIVE", "NEUTRAL", "POSITIVE"}:
                continue
            text = compact_text(row.get("content_text"))
            if not text:
                continue
            rows.append(
                {
                    "id": f"hf:{dataset}:{parquet_file.get('config')}:{parquet_file.get('split')}:{index}",
                    "source": f"hf_agent_trace_sentiment:{dataset}",
                    "dataset": dataset,
                    "config": parquet_file.get("config"),
                    "split": parquet_file.get("split"),
                    "row_idx": index,
                    "text": text,
                    "label": int(label == "NEGATIVE"),
                    "sentiment_label": label,
                    "agent": row.get("agent"),
                    "source_dataset": row.get("source_dataset"),
                    "n_errors": row.get("n_errors"),
                    "n_tool_calls": row.get("n_tool_calls"),
                }
            )
    print(json.dumps({"dataset": dataset, "parquet_rows": len(rows), "parquet_files": len(files)}, sort_keys=True), flush=True)
    return rows


def group_matches(label_file: str, patterns: list[str]) -> bool:
    return any(fnmatch.fnmatch(label_file, pattern) for pattern in patterns)


def load_private_rows(corpus_path: Path, audit_dir: Path, holdout_patterns: list[str]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    corpus = load_corpora([corpus_path])
    labels = label_rows(audit_dir)
    holdout_label_rows = [row for row in labels if group_matches(str(row["label_file"]), holdout_patterns)]
    holdout_ids = {str(row["record_id"]) for row in holdout_label_rows}
    train_label_rows = [
        row
        for row in labels
        if str(row["record_id"]) not in holdout_ids and not group_matches(str(row["label_file"]), holdout_patterns)
    ]

    def materialize(label_subset: list[dict[str, Any]], split_name: str) -> list[dict[str, Any]]:
        output: list[dict[str, Any]] = []
        for record_id, should_wake in resolved_labels(label_subset).items():
            record = corpus.get(record_id)
            if not record:
                continue
            output.append(
                {
                    "id": record_id,
                    "source": record.get("source") or "unknown",
                    "split_name": split_name,
                    "text": compact_text(record.get("text")),
                    "label": int(bool(should_wake)),
                }
            )
        return output

    return materialize(train_label_rows, "private_train"), materialize(holdout_label_rows, "private_holdout")


def split_rows(rows: list[dict[str, Any]], test_size: float, seed: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    y = [int(row["label"]) for row in rows]
    if len(set(y)) < 2 or len(rows) < 5:
        return rows, []
    train, test = train_test_split(rows, test_size=test_size, random_state=seed, stratify=y)
    return list(train), list(test)


def labels(rows: list[dict[str, Any]]) -> np.ndarray:
    return np.array([int(row["label"]) for row in rows], dtype=np.int64)


def quantiles(scores: np.ndarray) -> dict[str, float]:
    if len(scores) == 0:
        return {}
    return {str(q): float(np.quantile(scores, q)) for q in [0.05, 0.25, 0.5, 0.75, 0.95]}


def auc_metrics(y_true: np.ndarray, scores: np.ndarray) -> dict[str, float]:
    out: dict[str, float] = {}
    if len(y_true) and len(set(map(int, y_true))) == 2:
        out["average_precision"] = float(average_precision_score(y_true, scores))
        out["roc_auc"] = float(roc_auc_score(y_true, scores))
    return out


def metrics_at_threshold(y_true: np.ndarray, scores: np.ndarray, threshold: float) -> dict[str, Any]:
    row = metric_row(y_true, scores, threshold)
    row.update(auc_metrics(y_true, scores))
    positives = scores[y_true == 1]
    negatives = scores[y_true == 0]
    row["positive_score_quantiles"] = quantiles(positives)
    row["negative_score_quantiles"] = quantiles(negatives)
    return row


def select_threshold(y_dev: np.ndarray, dev_scores: np.ndarray, precision_floor: float) -> dict[str, Any]:
    selected = best_at_precision(y_dev, dev_scores, precision_floor)
    selected["average_precision"] = auc_metrics(y_dev, dev_scores).get("average_precision", 0.0)
    selected["roc_auc"] = auc_metrics(y_dev, dev_scores).get("roc_auc", 0.0)
    return selected


def result_sort_key(row: dict[str, Any]) -> tuple[float, float, float, float, float]:
    private = row["evals"].get("private_holdout") or {}
    dev = row["dev_selection"]
    return (
        float(private.get("average_precision", 0.0)),
        float(private.get("recall", 0.0)),
        float(private.get("precision", 0.0)),
        float(dev.get("recall", 0.0)),
        -float(private.get("wake_rate", 1.0)),
    )


def train_and_eval(
    *,
    name: str,
    config: dict[str, Any],
    train_rows: list[dict[str, Any]],
    train_y: list[int],
    train_weights: list[float] | None,
    dev_rows: list[dict[str, Any]],
    eval_sets: dict[str, list[dict[str, Any]]],
    precision_floor: float,
) -> tuple[dict[str, Any], Any]:
    model = make_model(**config)
    fit_model(model, train_rows, train_y, train_weights)
    y_dev = labels(dev_rows)
    dev_scores = scores_for(model, dev_rows)
    selected = select_threshold(y_dev, dev_scores, precision_floor)
    threshold = float(selected["threshold"])
    evals: dict[str, Any] = {}
    for eval_name, rows in eval_sets.items():
        if not rows:
            continue
        y_true = labels(rows)
        scores = scores_for(model, rows)
        evals[eval_name] = metrics_at_threshold(y_true, scores, threshold)
    result = {
        "name": name,
        "config": config,
        "config_name": config_name(config),
        "threshold": threshold,
        "dev_selection": selected,
        "evals": evals,
        "train_rows": len(train_rows),
        "train_positive": int(sum(train_y)),
        "train_weighted_positive": float(sum(w * y for w, y in zip(train_weights or [1.0] * len(train_y), train_y))),
        "train_weighted_total": float(sum(train_weights or [1.0] * len(train_y))),
    }
    return result, model


def fmt_metric(row: dict[str, Any]) -> str:
    return (
        f"{float(row.get('precision', 0.0)):.4f} | {float(row.get('recall', 0.0)):.4f} | "
        f"{float(row.get('wake_rate', 0.0)):.4f} | {int(row.get('tp', 0))} | {int(row.get('fp', 0))} | "
        f"{int(row.get('fn', 0))} | {int(row.get('tn', 0))} | "
        f"{float(row.get('average_precision', 0.0)):.4f} | {float(row.get('roc_auc', 0.0)):.4f}"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--public-cache", type=Path, default=DEFAULT_PUBLIC_CACHE)
    parser.add_argument("--refresh-public", action="store_true")
    parser.add_argument("--page-size", type=int, default=100)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--holdout-pattern", action="append", default=[])
    parser.add_argument("--precision-floor", type=float, default=0.90)
    parser.add_argument("--public-weight", default="0.25,0.5,1.0")
    parser.add_argument("--prefix-field-sets", default="source;none")
    parser.add_argument("--feature-sizes", default="30000,60000")
    parser.add_argument("--c-values", default="0.5,1.0,2.0,4.0")
    parser.add_argument("--class-weights", default="none,balanced")
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--json-output", type=Path, default=DEFAULT_JSON)
    args = parser.parse_args()

    holdout_patterns = args.holdout_pattern or ["*round9*.jsonl"]
    public_rows = fetch_public_rows(args.dataset, args.public_cache, refresh=args.refresh_public, page_size=args.page_size)
    private_train_all, private_holdout = load_private_rows(args.corpus, args.audit_dir, holdout_patterns)
    public_train_all, public_test = split_rows(public_rows, 0.20, 42)
    public_train, public_dev = split_rows(public_train_all, 0.20, 43)
    private_train, private_dev = split_rows(private_train_all, 0.20, 44)

    if not public_train or not private_train or not private_holdout:
        raise SystemExit("Need public rows, private train rows, and private holdout rows")

    prefix_field_sets: list[list[str]] = []
    for raw_set in args.prefix_field_sets.split(";"):
        value = raw_set.strip()
        if not value or value == "none":
            prefix_field_sets.append([])
        else:
            prefix_field_sets.append([field for field in value.split(",") if field])
    feature_sizes = [int(value) for value in args.feature_sizes.split(",") if value]
    c_values = [float(value) for value in args.c_values.split(",") if value]
    class_weights = [None if value == "none" else value for value in args.class_weights.split(",") if value]
    public_weights = [float(value) for value in args.public_weight.split(",") if value]

    configs = [
        {
            "prefix_fields": prefix_fields,
            "max_word_features": feature_size,
            "max_char_features": feature_size,
            "c_value": c_value,
            "class_weight": class_weight,
        }
        for prefix_fields in prefix_field_sets
        for feature_size in feature_sizes
        for c_value in c_values
        for class_weight in class_weights
    ]

    train_specs: list[tuple[str, list[dict[str, Any]], list[int], list[float] | None, list[dict[str, Any]]]] = []
    train_specs.append(("private_only", private_train, [int(r["label"]) for r in private_train], None, private_dev))
    train_specs.append(("public_only", public_train, [int(r["label"]) for r in public_train], None, public_dev))
    for public_weight in public_weights:
        rows = private_train + public_train
        y = [int(r["label"]) for r in rows]
        weights = [1.0] * len(private_train) + [public_weight] * len(public_train)
        dev_rows = private_dev + public_dev
        train_specs.append((f"private_plus_public_w{public_weight:g}", rows, y, weights, dev_rows))

    eval_sets = {
        "private_dev": private_dev,
        "private_holdout": private_holdout,
        "public_test": public_test,
        "combined_test": private_holdout + public_test,
    }

    best: dict[str, Any] | None = None
    best_model: Any | None = None
    results: list[dict[str, Any]] = []
    for config in configs:
        for spec_name, rows, y, weights, dev_rows in train_specs:
            if len(set(y)) < 2 or len(set(int(row["label"]) for row in dev_rows)) < 2:
                continue
            result, model = train_and_eval(
                name=spec_name,
                config=config,
                train_rows=rows,
                train_y=y,
                train_weights=weights,
                dev_rows=dev_rows,
                eval_sets=eval_sets,
                precision_floor=args.precision_floor,
            )
            results.append(result)
            private_metric = result["evals"].get("private_holdout", {})
            print(
                json.dumps(
                    {
                        "candidate": result["name"],
                        "config": result["config_name"],
                        "threshold": result["threshold"],
                        "private_holdout_precision": private_metric.get("precision"),
                        "private_holdout_recall": private_metric.get("recall"),
                        "private_holdout_average_precision": private_metric.get("average_precision"),
                    },
                    sort_keys=True,
                ),
                flush=True,
            )
            if best is None or result_sort_key(result) > result_sort_key(best):
                best = result
                best_model = model

    if best is None or best_model is None:
        raise SystemExit("No candidate evaluated")

    final_rows = private_train_all + public_train_all
    final_y = [int(row["label"]) for row in final_rows]
    if best["name"].startswith("private_plus_public_w"):
        value = best["name"].rsplit("w", 1)[1]
        public_weight = float(value)
        final_weights = [1.0] * len(private_train_all) + [public_weight] * len(public_train_all)
    elif best["name"] == "public_only":
        final_rows = public_train_all
        final_y = [int(row["label"]) for row in final_rows]
        final_weights = None
    else:
        final_rows = private_train_all
        final_y = [int(row["label"]) for row in final_rows]
        final_weights = None

    final_model = make_model(**best["config"])
    fit_model(final_model, final_rows, final_y, final_weights)
    final_threshold = float(best["threshold"])
    final_evals: dict[str, Any] = {}
    for eval_name, rows in eval_sets.items():
        if not rows:
            continue
        final_evals[eval_name] = metrics_at_threshold(labels(rows), scores_for(final_model, rows), final_threshold)

    report_payload = {
        "signal_name": "agent_negative_feedback_score",
        "selected_threshold": final_threshold,
        "precision_floor": args.precision_floor,
        "selected_training_pool": best["name"],
        "selected_config": best["config_name"],
        "public_dataset": args.dataset,
        "public_rows": len(public_rows),
        "private_train_rows": len(private_train_all),
        "private_holdout_rows": len(private_holdout),
        "private_holdout_patterns": holdout_patterns,
        "private_holdout_metrics": final_evals.get("private_holdout"),
        "public_test_metrics": final_evals.get("public_test"),
    }
    export_model(final_model, args.json_output, final_threshold, best["config"]["prefix_fields"], report_payload)
    retag_export(args.json_output)

    ranked = sorted(results, key=result_sort_key, reverse=True)
    label_counts = {
        "public": dict(Counter(row["label"] for row in public_rows)),
        "private_train": dict(Counter(row["label"] for row in private_train_all)),
        "private_holdout": dict(Counter(row["label"] for row in private_holdout)),
    }
    lines = ["# Agent Negative Feedback Classifier Report", ""]
    lines.append("Signal: `agent_negative_feedback_score`")
    lines.append("Use: thresholded wake/count signal and continuous negative reward signal")
    lines.append(f"Public dataset: https://huggingface.co/datasets/{args.dataset}")
    lines.append(f"Public rows: {len(public_rows)}")
    lines.append(f"Private train rows: {len(private_train_all)}")
    lines.append(f"Private holdout rows: {len(private_holdout)}")
    lines.append(f"Private holdout patterns: {', '.join(holdout_patterns)}")
    lines.append(f"Label counts: `{json.dumps(label_counts, sort_keys=True)}`")
    lines.append(f"Precision floor for wake threshold selection: {args.precision_floor:.3f}")
    lines.append(f"Selected training pool: `{best['name']}`")
    lines.append(f"Selected config: `{best['config_name']}`")
    lines.append(f"Selected threshold: {float(best['threshold']):.3f}")
    lines.append(f"Export JSON: {args.json_output}")
    lines.append("")
    lines.append("## Selected Metrics")
    lines.append("")
    lines.append("| eval set | precision | recall | wake rate | TP | FP | FN | TN | avg precision | ROC AUC |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for eval_name in ["private_dev", "private_holdout", "public_test", "combined_test"]:
        metric = final_evals.get(eval_name)
        if metric:
            lines.append(f"| {eval_name} | {fmt_metric(metric)} |")
    lines.append("")
    lines.append("## Score Quantiles For Selected Model")
    lines.append("")
    for eval_name in ["private_holdout", "public_test"]:
        metric = best["evals"].get(eval_name) or {}
        lines.append(f"### {eval_name}")
        lines.append(f"Positive labels: `{json.dumps(metric.get('positive_score_quantiles', {}), sort_keys=True)}`")
        lines.append(f"Negative labels: `{json.dumps(metric.get('negative_score_quantiles', {}), sort_keys=True)}`")
        lines.append("")
    lines.append("## Top Candidates")
    lines.append("")
    lines.append("| rank | pool | threshold | private AP | private precision | private recall | public AP | public precision | public recall | config |")
    lines.append("| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |")
    for index, row in enumerate(ranked[:30], 1):
        private_metric = row["evals"].get("private_holdout", {})
        public_metric = row["evals"].get("public_test", {})
        lines.append(
            "| {rank} | `{pool}` | {threshold:.3f} | {private_ap:.4f} | {private_p:.4f} | {private_r:.4f} | {public_ap:.4f} | {public_p:.4f} | {public_r:.4f} | `{config}` |".format(
                rank=index,
                pool=row["name"],
                threshold=float(row["threshold"]),
                private_ap=float(private_metric.get("average_precision", 0.0)),
                private_p=float(private_metric.get("precision", 0.0)),
                private_r=float(private_metric.get("recall", 0.0)),
                public_ap=float(public_metric.get("average_precision", 0.0)),
                public_p=float(public_metric.get("precision", 0.0)),
                public_r=float(public_metric.get("recall", 0.0)),
                config=row["config_name"],
            )
        )

    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text("\n".join(lines) + "\n")
    print(args.report)
    print(args.json_output)


if __name__ == "__main__":
    main()
