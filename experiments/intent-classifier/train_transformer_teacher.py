#!/usr/bin/env python3
"""Train a GPU transformer teacher for Introspect wake intent labels."""

from __future__ import annotations

import argparse
import fnmatch
import json
import math
import random
from collections import Counter
from pathlib import Path
from typing import Any

import numpy as np
import torch
from sklearn.model_selection import train_test_split
from torch.utils.data import DataLoader, Dataset
from transformers import AutoModelForSequenceClassification, AutoTokenizer, get_linear_schedule_with_warmup


REPO = Path(__file__).resolve().parents[2]
DEFAULT_CORPUS = REPO / "feedback" / "intent-classifier" / "chat-corpus.jsonl"
DEFAULT_LABEL_DIR = REPO / "feedback" / "intent-classifier" / "subagent-labels"
DEFAULT_OUTPUT = REPO / "feedback" / "intent-classifier" / "transformer-teacher"
DEFAULT_REPORT = REPO / "feedback" / "intent-classifier" / "transformer-teacher-report.md"


def read_jsonl(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        return []
    with path.open() as handle:
        return [json.loads(line) for line in handle if line.strip()]


def compact_text(text: str) -> str:
    return " ".join(str(text).split())


def example_text(row: dict[str, Any]) -> str:
    return f"source={row.get('source') or 'unknown'}\n{compact_text(row.get('text', ''))}"


def load_corpus(path: Path) -> dict[str, dict[str, Any]]:
    return {str(row["id"]): row for row in read_jsonl(path) if row.get("id")}


def load_labels(label_dir: Path, holdout_patterns: list[str]) -> tuple[dict[str, bool], dict[str, bool], list[dict[str, Any]]]:
    train_votes: dict[str, list[bool]] = {}
    holdout_votes: dict[str, list[bool]] = {}
    raw_rows: list[dict[str, Any]] = []
    for path in sorted(label_dir.glob("*.jsonl")):
        is_holdout = any(fnmatch.fnmatch(path.name, pattern) for pattern in holdout_patterns)
        for row in read_jsonl(path):
            record_id = row.get("record_id")
            if not record_id:
                continue
            if not isinstance(row.get("should_wake"), bool):
                continue
            merged = dict(row)
            merged["label_file"] = path.name
            raw_rows.append(merged)
            target = holdout_votes if is_holdout else train_votes
            target.setdefault(str(record_id), []).append(bool(row["should_wake"]))

    def resolve(votes: dict[str, list[bool]]) -> dict[str, bool]:
        resolved: dict[str, bool] = {}
        for record_id, values in votes.items():
            counts = Counter(values)
            resolved[record_id] = counts[True] >= counts[False]
        return resolved

    return resolve(train_votes), resolve(holdout_votes), raw_rows


def rows_from_labels(corpus: dict[str, dict[str, Any]], labels: dict[str, bool]) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    for record_id, should_wake in labels.items():
        record = corpus.get(record_id)
        if not record:
            continue
        merged = dict(record)
        merged["label"] = int(should_wake)
        rows.append(merged)
    return rows


class IntentDataset(Dataset):
    def __init__(self, rows: list[dict[str, Any]], tokenizer: Any, max_length: int) -> None:
        self.rows = rows
        self.encoded = tokenizer(
            [example_text(row) for row in rows],
            truncation=True,
            max_length=max_length,
            padding="max_length",
        )
        self.labels = [int(row["label"]) for row in rows]

    def __len__(self) -> int:
        return len(self.rows)

    def __getitem__(self, index: int) -> dict[str, torch.Tensor]:
        item = {key: torch.tensor(value[index], dtype=torch.long) for key, value in self.encoded.items()}
        item["labels"] = torch.tensor(self.labels[index], dtype=torch.long)
        return item


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
    return [round(value / 1000, 3) for value in range(50, 951, 5)]


def best_at_precision(y_true: np.ndarray, scores: np.ndarray, floor: float) -> dict[str, float | int]:
    rows = [metric_row(y_true, scores, threshold) for threshold in threshold_grid()]
    viable = [row for row in rows if float(row["precision"]) >= floor and int(row["tp"]) > 0]
    if not viable:
        return max(rows, key=lambda row: (float(row["precision"]), float(row["recall"])))
    return max(viable, key=lambda row: (float(row["recall"]), float(row["precision"]), -float(row["wake_rate"])))


def predict_scores(model: torch.nn.Module, loader: DataLoader, device: torch.device) -> tuple[np.ndarray, np.ndarray]:
    model.eval()
    y_true: list[int] = []
    scores: list[float] = []
    with torch.no_grad():
        for batch in loader:
            labels = batch.pop("labels")
            batch = {key: value.to(device) for key, value in batch.items()}
            logits = model(**batch).logits.float().cpu()
            probs = torch.softmax(logits, dim=-1)[:, 1]
            y_true.extend(labels.numpy().astype(int).tolist())
            scores.extend(probs.numpy().astype(float).tolist())
    return np.array(y_true, dtype=np.int64), np.array(scores, dtype=np.float64)


def counts(rows: list[dict[str, Any]]) -> tuple[int, int]:
    positives = sum(int(row["label"]) for row in rows)
    return positives, len(rows) - positives


def write_report(
    path: Path,
    *,
    args: argparse.Namespace,
    train_rows: list[dict[str, Any]],
    dev_rows: list[dict[str, Any]],
    test_rows: list[dict[str, Any]],
    dev_best: dict[str, float | int],
    test_best: dict[str, float | int],
    test_at_dev_threshold: dict[str, float | int],
) -> None:
    train_pos, train_neg = counts(train_rows)
    dev_pos, dev_neg = counts(dev_rows)
    test_pos, test_neg = counts(test_rows)
    lines = ["# Transformer Teacher Report", ""]
    lines.append(f"Model: `{args.model_id}`")
    lines.append(f"Output: `{args.output_dir}`")
    lines.append(f"Holdout patterns: `{','.join(args.holdout_pattern)}`")
    lines.append(f"Epochs: {args.epochs}")
    lines.append(f"Max length: {args.max_length}")
    lines.append(f"Device: `{args.resolved_device}`")
    lines.append("")
    lines.append("| split | rows | wake | no wake |")
    lines.append("| --- | ---: | ---: | ---: |")
    lines.append(f"| train | {len(train_rows)} | {train_pos} | {train_neg} |")
    lines.append(f"| dev | {len(dev_rows)} | {dev_pos} | {dev_neg} |")
    lines.append(f"| hard holdout | {len(test_rows)} | {test_pos} | {test_neg} |")
    lines.append("")
    lines.append("## Metrics")
    lines.append("")
    lines.append("| split | threshold | precision | recall | wake rate | TP | FP | FN | TN |")
    lines.append("| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |")
    lines.append(
        "| dev best | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **dev_best
        )
    )
    lines.append(
        "| holdout best | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **test_best
        )
    )
    lines.append(
        "| holdout at dev threshold | {threshold:.3f} | {precision:.4f} | {recall:.4f} | {wake_rate:.4f} | {tp} | {fp} | {fn} | {tn} |".format(
            **test_at_dev_threshold
        )
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--label-dir", type=Path, default=DEFAULT_LABEL_DIR)
    parser.add_argument("--model-id", default="microsoft/deberta-v3-small")
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--report", type=Path, default=DEFAULT_REPORT)
    parser.add_argument("--holdout-pattern", action="append", default=None)
    parser.add_argument("--epochs", type=int, default=4)
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--gradient-accumulation-steps", type=int, default=1)
    parser.add_argument("--lr", type=float, default=2e-5)
    parser.add_argument("--max-length", type=int, default=384)
    parser.add_argument("--precision-floor", type=float, default=0.95)
    parser.add_argument("--progress-every", type=int, default=50)
    parser.add_argument("--amp", action="store_true")
    parser.add_argument("--device", choices=["auto", "cuda", "mps", "cpu"], default="auto")
    parser.add_argument("--require-cuda", action="store_true")
    parser.add_argument("--seed", type=int, default=20260617)
    args = parser.parse_args()
    if args.holdout_pattern is None:
        args.holdout_pattern = ["*round5*.jsonl"]

    random.seed(args.seed)
    np.random.seed(args.seed)
    torch.manual_seed(args.seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(args.seed)

    corpus = load_corpus(args.corpus)
    train_labels, holdout_labels, _raw = load_labels(args.label_dir, args.holdout_pattern)
    train_pool = rows_from_labels(corpus, train_labels)
    test_rows = rows_from_labels(corpus, holdout_labels)
    if len(set(row["label"] for row in train_pool)) < 2:
        raise SystemExit("Need both train classes")
    if not test_rows:
        raise SystemExit("Holdout pattern produced no test rows")

    y = np.array([row["label"] for row in train_pool], dtype=np.int64)
    train_rows, dev_rows = train_test_split(
        train_pool,
        test_size=0.18,
        random_state=args.seed,
        stratify=y,
    )

    tokenizer = AutoTokenizer.from_pretrained(args.model_id, use_fast=True, trust_remote_code=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForSequenceClassification.from_pretrained(args.model_id, num_labels=2, trust_remote_code=True)
    model.float()
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
        raise SystemExit("CUDA is required for this run; refusing to train transformer teacher on CPU")
    model.to(device)

    train_loader = DataLoader(
        IntentDataset(train_rows, tokenizer, args.max_length),
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=2,
        pin_memory=torch.cuda.is_available(),
    )
    dev_loader = DataLoader(IntentDataset(dev_rows, tokenizer, args.max_length), batch_size=args.batch_size)
    test_loader = DataLoader(IntentDataset(test_rows, tokenizer, args.max_length), batch_size=args.batch_size)

    pos, neg = counts(train_rows)
    class_weights = torch.tensor(
        [len(train_rows) / max(1, 2 * neg), len(train_rows) / max(1, 2 * pos)],
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
    loss_fn = torch.nn.CrossEntropyLoss(weight=class_weights)
    use_amp = bool(args.amp and device.type == "cuda")

    for epoch in range(args.epochs):
        model.train()
        total_loss = 0.0
        optimizer.zero_grad(set_to_none=True)
        for step, batch in enumerate(train_loader, 1):
            labels = batch.pop("labels").to(device)
            batch = {key: value.to(device) for key, value in batch.items()}
            with torch.autocast(device_type="cuda", dtype=torch.bfloat16, enabled=use_amp):
                logits = model(**batch).logits
                loss = loss_fn(logits.float(), labels)
            if not torch.isfinite(loss):
                raise RuntimeError(f"non-finite training loss at epoch {epoch + 1}")
            (loss / accumulation_steps).backward()
            if step % accumulation_steps == 0 or step == len(train_loader):
                torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
                optimizer.step()
                scheduler.step()
                optimizer.zero_grad(set_to_none=True)
            total_loss += float(loss.detach().cpu())
            if args.progress_every > 0 and (step % args.progress_every == 0 or step == len(train_loader)):
                print(
                    json.dumps(
                        {
                            "epoch": epoch + 1,
                            "step": step,
                            "steps": len(train_loader),
                            "loss": total_loss / step,
                        }
                    ),
                    flush=True,
                )
        print(json.dumps({"epoch": epoch + 1, "loss": total_loss / max(1, len(train_loader))}), flush=True)

    dev_y, dev_scores = predict_scores(model, dev_loader, device)
    test_y, test_scores = predict_scores(model, test_loader, device)
    dev_best = best_at_precision(dev_y, dev_scores, args.precision_floor)
    test_best = best_at_precision(test_y, test_scores, args.precision_floor)
    test_at_dev_threshold = metric_row(test_y, test_scores, float(dev_best["threshold"]))

    args.output_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(args.output_dir)
    tokenizer.save_pretrained(args.output_dir)
    with (args.output_dir / "holdout_scores.jsonl").open("w") as handle:
        for row, score in zip(test_rows, test_scores):
            handle.write(
                json.dumps(
                    {
                        "record_id": row["id"],
                        "source": row.get("source"),
                        "label": int(row["label"]),
                        "score": float(score),
                    },
                    ensure_ascii=False,
                )
                + "\n"
            )
    write_report(
        args.report,
        args=args,
        train_rows=train_rows,
        dev_rows=dev_rows,
        test_rows=test_rows,
        dev_best=dev_best,
        test_best=test_best,
        test_at_dev_threshold=test_at_dev_threshold,
    )
    print(args.report)


if __name__ == "__main__":
    main()
