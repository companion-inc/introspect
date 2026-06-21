#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REMOTE_HOST="${INTROSPECT_DGX_HOST:-dgx}"
REMOTE_DIR="${INTROSPECT_DGX_REPO:-/home/introspect/introspect}"
MODEL_ID="${INTROSPECT_INTENT_MODEL_ID:-Qwen/Qwen3-30B-A3B-Instruct-2507}"
HOLDOUT_PATTERN="${INTROSPECT_INTENT_HOLDOUT_PATTERN:-*round8*.jsonl}"
RUN_NAME="${INTROSPECT_INTENT_RUN_NAME:-qwen3-30b-round8-teacher}"
REMOTE_OUTPUT="feedback/intent-classifier/transformer-teacher-${RUN_NAME}"
REMOTE_REPORT="feedback/intent-classifier/transformer-teacher-${RUN_NAME}-report.md"
LOCAL_SCORES="feedback/intent-classifier/transformer-teacher-${RUN_NAME}-holdout-scores.jsonl"

# This trains a teacher on the DGX only. The Introspect hook must still ship a
# compact exported student model, not this transformer checkpoint.

ssh -o ConnectTimeout=8 -o ConnectionAttempts=1 "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/experiments/intent-classifier' '$REMOTE_DIR/feedback/intent-classifier/subagent-labels'"

rsync -az "$REPO/experiments/intent-classifier/train_transformer_teacher.py" \
  "$REMOTE_HOST:$REMOTE_DIR/experiments/intent-classifier/train_transformer_teacher.py"
rsync -az "$REPO/feedback/intent-classifier/chat-corpus.jsonl" \
  "$REMOTE_HOST:$REMOTE_DIR/feedback/intent-classifier/chat-corpus.jsonl"
rsync -az "$REPO/feedback/intent-classifier/subagent-labels/" \
  "$REMOTE_HOST:$REMOTE_DIR/feedback/intent-classifier/subagent-labels/"

ssh "$REMOTE_HOST" "cd '$REMOTE_DIR' && \
  if command -v uv >/dev/null 2>&1; then \
    uv run --with torch --with transformers --with scikit-learn --with numpy \
      python experiments/intent-classifier/train_transformer_teacher.py \
        --model-id '$MODEL_ID' \
        --holdout-pattern '$HOLDOUT_PATTERN' \
        --output-dir '$REMOTE_OUTPUT' \
        --report '$REMOTE_REPORT' \
        --epochs 5 \
        --batch-size 4 \
        --gradient-accumulation-steps 8 \
        --lr 1e-5 \
        --max-length 512 \
        --precision-floor 0.95 \
        --progress-every 10 \
        --amp \
        --require-cuda; \
  else \
    python3 experiments/intent-classifier/train_transformer_teacher.py \
        --model-id '$MODEL_ID' \
        --holdout-pattern '$HOLDOUT_PATTERN' \
        --output-dir '$REMOTE_OUTPUT' \
        --report '$REMOTE_REPORT' \
        --epochs 5 \
        --batch-size 4 \
        --gradient-accumulation-steps 8 \
        --lr 1e-5 \
        --max-length 512 \
        --precision-floor 0.95 \
        --progress-every 10 \
        --amp \
        --require-cuda; \
  fi"

rsync -az "$REMOTE_HOST:$REMOTE_DIR/$REMOTE_REPORT" \
  "$REPO/feedback/intent-classifier/"
rsync -az "$REMOTE_HOST:$REMOTE_DIR/$REMOTE_OUTPUT/holdout_scores.jsonl" \
  "$REPO/$LOCAL_SCORES"

echo "$REPO/feedback/intent-classifier/$(basename "$REMOTE_REPORT")"
