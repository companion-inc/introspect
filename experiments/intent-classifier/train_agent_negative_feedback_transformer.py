#!/usr/bin/env python3
"""Train a tiny transformer comparator for agent-negative-feedback scoring."""

from __future__ import annotations

import argparse
import json
import math
import random
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
import torch
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import train_test_split
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer, get_linear_schedule_with_warmup

from train_agent_negative_feedback import (
    DEFAULT_AUDIT_DIR,
    DEFAULT_CORPUS,
    DEFAULT_DATASET,
    DEFAULT_PUBLIC_CACHE,
    compact_text,
    fetch_public_rows,
    load_private_rows,
    metric_row,
)


REPO = Path(__file__).resolve().parents[2]
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "agent-negative-feedback-transformer"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "agent-negative-feedback-transformer-report.md"


def example_text(row: dict[str, Any], prefix_fields: list[str]) -> str:
    prefix: list[str] = []
    if "source" in prefix_fields:
        prefix.append(f"source={row.get('source') or 'unknown'}")
    body = compact_text(row.get("text", ""))
    return (" ".join(prefix) + "\n" + body) if prefix else body


class FeedbackDataset(Dataset):
    def __init__(self, rows: list[dict[str, Any]], tokenizer: Any, max_length: int, prefix_fields: list[str]) -> None:
        self.rows = rows
        self.encoded = tokenizer(
            [example_text(row, prefix_fields) for row in rows],
            truncation=True,
            max_length=max_length,
            padding="max_length",
        )
        self.labels = [int(row["label"]) for row in rows]
        self.weights = [float(row.get("weight", 1.0)) for row in rows]

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        item = {key: torch.tensor(value[index], dtype=torch.long) for key, value in self.encoded.items()}
        item["labels"] = torch.tensor(self.labels[index], dtype=torch.long)
        item["weights"] = torch.tensor(self.weights[index], dtype=torch.float32)
        return item


def split_rows(rows: list[dict[str, Any]], test_size: float, seed: int) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    y = [int(row["label"]) for row in rows]
    if len(set(y)) < 2:
        return rows, []
    train, test = train_test_split(rows, test_size=test_size, random_state=seed, stratify=y)
    return list(train), list(test)


def counts(rows: list[dict[str, Any]]) -> tuple[int, int]:
    positives = sum(int(row["label"]) for row in rows)
    return positives, len(rows) - positives


def labels(rows: list[dict[str, Any]]) -> np.ndarray:
    return np.array([int(row["label"]) for row in rows], dtype=np.int64)


def threshold_grid() -> list[float]:
    return [round(value / 1000, 3) for value in range(50, 951, 5)]


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= floor and int(row["tp"]) > 0]
    if viable:
        return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))
    return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"])))


def auc_metrics(y_true: np.ndarray, scores: np.ndarray) -> dict[str, float]:
    if len(y_true) == 0 or len(set(map(int, y_true))) < 2:
        return {"average_precision": 0.0, "roc_auc": 0.0}
    return {
        "average_precision": float(average_precision_score(y_true, scores)),
        "roc_auc": float(roc_auc_score(y_true, scores)),
    }


def metrics_at(y_true: np.ndarray, scores: np.ndarray, threshold: float) -> dict[str, Any]:
    row = metric_row(y_true, scores, threshold)
    row.update(auc_metrics(y_true, scores))
    return row


def predict_scores(model: torch.nn.Module, loader: DataLoader, device: torch.device) -> tuple[np.ndarray, np.ndarray]:
    model.eval()
    y_true: list[int] = []
    scores: list[float] = []
    with torch.no_grad():
        for batch in loader:
            labels = batch.pop("labels")
            batch.pop("weights", None)
            batch = {key: value.to(device) for key, value in batch.items()}
            logits = model(**batch).logits.float().cpu()
            probs = torch.softmax(logits, dim=-1)[:, 1]
            y_true.extend(labels.numpy().astype(int).tolist())
            scores.extend(probs.numpy().astype(float).tolist())
    return np.array(y_true, dtype=np.int64), np.array(scores, dtype=np.float64)


def score_texts(model: torch.nn.Module, tokenizer: Any, texts: list[str], device: torch.device, max_length: int) -> list[float]:
    model.eval()
    encoded = tokenizer(texts, truncation=True, max_length=max_length, padding=True, return_tensors="pt")
    encoded = {key: value.to(device) for key, value in encoded.items()}
    with torch.no_grad():
        logits = model(**encoded).logits.float().cpu()
    return torch.softmax(logits, dim=-1)[:, 1].numpy().astype(float).tolist()


def write_report(
    path: Path,
    *,
    args: argparse.Namespace,
    train_rows: list[dict[str, Any]],
    private_dev: dict[str, Any],
    private_holdout: dict[str, Any],
    public_test: dict[str, Any],
    probes: list[dict[str, Any]],
) -> None:
    train_pos, train_neg = counts(train_rows)
    lines = ["# Agent Negative Feedback Transformer Report", ""]
    lines.append("Signal: `agent_negative_feedback_score`")
    lines.append(f"Model: `{args.model_id}`")
    lines.append(f"Output: `{args.output_dir}`")
    lines.append(f"Public dataset: https://huggingface.co/datasets/{args.dataset}")
    lines.append(f"Public weight: {args.public_weight:.3f}")
    lines.append(f"Prefix fields: `{','.join(args.prefix_fields) or 'none'}`")
    lines.append(f"Device: `{args.resolved_device}`")
    lines.append(f"Epochs: {args.epochs}")
    lines.append(f"Max length: {args.max_length}")
    lines.append("")
    lines.append("| split | rows | positive | negative |")
    lines.append("| --- | ---: | ---: | ---: |")
    lines.append(f"| train | {len(train_rows)} | {train_pos} | {train_neg} |")
    lines.append("")
    lines.append("## Metrics")
    lines.append("")
    lines.append("| eval set | threshold | precision | recall | wake rate | TP | FP | FN | TN | avg precision | ROC AUC |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    for name, metric in [("private_dev", private_dev), ("private_holdout", private_holdout), ("public_test", public_test)]:
        lines.append(
            "| {name} | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} | {average_precision:.4f} | {roc_auc:.4f} |".format(
                name=name,
                **metric,
            )
        )
    lines.append("")
    lines.append("## Probe Scores")
    lines.append("")
    lines.append("| probe | score |")
    lines.append("| --- | ---: |")
    for probe in probes:
        lines.append(f"| {probe['name']} | {probe['score']:.4f} |")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--public-cache", type=Path, default=DEFAULT_PUBLIC_CACHE)
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--audit-dir", type=Path, default=DEFAULT_AUDIT_DIR)
    parser.add_argument("--holdout-pattern", action="append", default=[])
    parser.add_argument("--model-id", default="google/bert_uncased_L-2_H-128_A-2")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--public-weight", type=float, default=0.25)
    parser.add_argument("--prefix-fields", default="source")
    parser.add_argument("--precision-floor", type=float, default=0.90)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--lr", type=float, default=3e-5)
    parser.add_argument("--max-length", type=int, default=256)
    parser.add_argument("--amp", action="store_true")
    parser.add_argument("--device", choices=["auto", "cuda", "mps", "cpu"], default="auto")
    parser.add_argument("--require-cuda", action="store_true")
    parser.add_argument("--seed", type=int, default=20260618)
    args = parser.parse_args()

    holdout_patterns = args.holdout_pattern or ["*round9*.jsonl"]
    prefix_fields = [] if args.prefix_fields in {"", "none"} else [field for field in args.prefix_fields.split(",") if field]
    args.prefix_fields = prefix_fields

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    public_rows = fetch_public_rows(args.dataset, args.public_cache, refresh=False, page_size=100)
    private_train_all, private_holdout = load_private_rows(args.corpus, args.audit_dir, holdout_patterns)
    public_train_all, public_test = split_rows(public_rows, 0.20, args.seed + 1)
    private_train, private_dev_rows = split_rows(private_train_all, 0.18, args.seed + 2)

    train_rows: list[dict[str, Any]] = []
    for row in private_train:
        merged = dict(row)
        merged["weight"] = 1.0
        train_rows.append(merged)
    for row in public_train_all:
        merged = dict(row)
        merged["weight"] = args.public_weight
        train_rows.append(merged)

    tokenizer = AutoTokenizer.from_pretrained(args.model_id, use_fast=True, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForSequenceClassification.from_pretrained(args.model_id, num_labels=2, trust_remote_code=True)
    if getattr(model.config, "pad_token_id", None) is None and tokenizer.pad_token_id is not None:
        model.config.pad_token_id = tokenizer.pad_token_id

    if args.device == "auto":
        if torch.cuda.is_available():
            device = torch.device("cuda")
        elif hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
            device = torch.device("mps")
        else:
            device = torch.device("cpu")
    else:
        device = torch.device(args.device)
    args.resolved_device = str(device)
    if args.require_cuda and device.type != "cuda":
        raise SystemExit("CUDA is required for this run")
    model.to(device)

    train_loader = DataLoader(
        FeedbackDataset(train_rows, tokenizer, args.max_length, prefix_fields),
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=2,
        pin_memory=torch.cuda.is_available(),
    )
    dev_loader = DataLoader(FeedbackDataset(private_dev_rows, tokenizer, args.max_length, prefix_fields), batch_size=args.batch_size)
    holdout_loader = DataLoader(FeedbackDataset(private_holdout, tokenizer, args.max_length, prefix_fields), batch_size=args.batch_size)
    public_loader = DataLoader(FeedbackDataset(public_test, tokenizer, args.max_length, prefix_fields), batch_size=args.batch_size)

    weighted_pos = sum(float(row.get("weight", 1.0)) for row in train_rows if int(row["label"]))
    weighted_neg = sum(float(row.get("weight", 1.0)) for row in train_rows if not int(row["label"]))
    total_weight = max(1e-6, weighted_pos + weighted_neg)
    class_weights = torch.tensor(
        [total_weight / max(1e-6, 2 * weighted_neg), total_weight / max(1e-6, 2 * weighted_pos)],
        dtype=torch.float32,
        device=device,
    )
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr)
    accumulation_steps = max(1, args.gradient_accumulation_steps)
    total_steps = max(1, args.epochs * math.ceil(len(train_loader) / accumulation_steps))
    scheduler = get_linear_schedule_with_warmup(
        optimizer,
        num_warmup_steps=max(1, math.floor(total_steps * 0.08)),
        num_training_steps=total_steps,
    )
    loss_fn = torch.nn.CrossEntropyLoss(weight=class_weights, reduction="none")
    use_amp = bool(args.amp and device.type == "cuda")

    for epoch in range(args.epochs):
        model.train()
        total_loss = 0.0
        optimizer.zero_grad(set_to_none=True)
        for step, batch in enumerate(train_loader, 1):
            weights = batch.pop("weights").to(device)
            labels_tensor = batch.pop("labels").to(device)
            batch = {key: value.to(device) for key, value in batch.items()}
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=use_amp):
                logits = model(**batch).logits
                per_row_loss = loss_fn(logits.float(), labels_tensor)
                loss = (per_row_loss * weights).sum() / weights.sum().clamp_min(1e-6)
            if not torch.isfinite(loss):
                raise RuntimeError(f"non-finite loss at epoch {epoch + 1}")
            (loss / accumulation_steps).backward()
            if step % accumulation_steps == 0 or step == len(train_loader):
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad(set_to_none=True)
            total_loss += float(loss.detach().cpu())
            if step == len(train_loader) or (step % 25 == 0):
                print(json.dumps({"epoch": epoch + 1, "step": step, "steps": len(train_loader), "loss": total_loss / step}), flush=True)

    dev_y, dev_scores = predict_scores(model, dev_loader, device)
    holdout_y, holdout_scores = predict_scores(model, holdout_loader, device)
    public_y, public_scores = predict_scores(model, public_loader, device)
    dev_best = best_at_precision(dev_y, dev_scores, args.precision_floor)
    threshold = float(dev_best["threshold"])
    private_dev_metric = metrics_at(dev_y, dev_scores, threshold)
    private_holdout_metric = metrics_at(holdout_y, holdout_scores, threshold)
    public_test_metric = metrics_at(public_y, public_scores, threshold)

    probe_texts = {
        "normal_task": example_text({"source": "codex", "text": "please add a chart to the app showing counts by day"}, prefix_fields),
        "gentle_correction": example_text({"source": "codex", "text": "actually use the DGX for the training run and keep going"}, prefix_fields),
        "agent_failure": example_text({"source": "codex", "text": "why did you not test this properly? read the logs and fix the actual issue"}, prefix_fields),
        "wrong_target": example_text({"source": "codex", "text": "you ignored the instructions, used the wrong training target, and wasted compute"}, prefix_fields),
        "external_complaint": example_text({"source": "codex", "text": "the Cloudflare page is returning a 502 error and the app is down"}, prefix_fields),
    }
    probe_scores = score_texts(model, tokenizer, list(probe_texts.values()), device, args.max_length)
    probes = [
        {"name": name, "score": float(score)}
        for name, score in zip(probe_texts.keys(), probe_scores)
    ]

    args.output_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)
    with (args.output_dir / "holdout_scores.jsonl").open("w") as handle:
        for row, score in zip(private_holdout, holdout_scores):
            handle.write(json.dumps({"record_id": row["id"], "label": int(row["label"]), "score": float(score)}, ensure_ascii=False) + "\n")
    write_report(
        args.report,
        args=args,
        train_rows=train_rows,
        private_dev=private_dev_metric,
        private_holdout=private_holdout_metric,
        public_test=public_test_metric,
        probes=probes,
    )
    print(args.report)


if __name__ == "__main__":
    main()
