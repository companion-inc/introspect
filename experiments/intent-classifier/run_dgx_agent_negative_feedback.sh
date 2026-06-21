#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REMOTE_HOST="${INTROSPECT_DGX_HOST:-dgx}"
REMOTE_DIR="${INTROSPECT_DGX_REPO:-/home/introspect/introspect}"
RUN_NAME="${INTROSPECT_NEGATIVE_FEEDBACK_RUN_NAME:-public-private-r1}"
PRECISION_FLOOR="${INTROSPECT_NEGATIVE_FEEDBACK_PRECISION_FLOOR:-0.90}"
HOLDOUT_PATTERN="${INTROSPECT_NEGATIVE_FEEDBACK_HOLDOUT_PATTERN:-*round9*.jsonl}"
PUBLIC_WEIGHT="${INTROSPECT_NEGATIVE_FEEDBACK_PUBLIC_WEIGHT:-0.25,0.5,1.0}"
PREFIX_FIELD_SETS="${INTROSPECT_NEGATIVE_FEEDBACK_PREFIX_FIELD_SETS:-source;none}"
FEATURE_SIZES="${INTROSPECT_NEGATIVE_FEEDBACK_FEATURE_SIZES:-30000,60000}"
C_VALUES="${INTROSPECT_NEGATIVE_FEEDBACK_C_VALUES:-0.5,1.0,2.0,4.0}"
CLASS_WEIGHTS="${INTROSPECT_NEGATIVE_FEEDBACK_CLASS_WEIGHTS:-none,balanced}"
REMOTE_REPORT="feedback/intent-classifier/agent-negative-feedback-${RUN_NAME}-report.md"
REMOTE_JSON="feedback/intent-classifier/agent-negative-feedback-${RUN_NAME}.json"

ssh -o ConnectTimeout=8 -o ConnectionAttempts=1 "$REMOTE_HOST" \
  "mkdir -p '$REMOTE_DIR/experiments/intent-classifier' '$REMOTE_DIR/feedback/intent-classifier/subagent-labels'"

rsync -az "$REPO/experiments/intent-classifier/train_agent_negative_feedback.py" \
  "$REMOTE_HOST:$REMOTE_DIR/experiments/intent-classifier/train_agent_negative_feedback.py"
rsync -az "$REPO/experiments/intent-classifier/train_intent_v2_grid.py" \
  "$REMOTE_HOST:$REMOTE_DIR/experiments/intent-classifier/train_intent_v2_grid.py"
rsync -az "$REPO/feedback/intent-classifier/chat-corpus.jsonl" \
  "$REMOTE_HOST:$REMOTE_DIR/feedback/intent-classifier/chat-corpus.jsonl"
rsync -az "$REPO/feedback/intent-classifier/subagent-labels/" \
  "$REMOTE_HOST:$REMOTE_DIR/feedback/intent-classifier/subagent-labels/"

ssh "$REMOTE_HOST" "export PATH=\"\$HOME/.local/bin:\$PATH\" && cd '$REMOTE_DIR' && \
  echo dgx_host=\$(hostname) && \
  command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,memory.total --format=csv,noheader || true && \
  if command -v uv >/dev/null 2>&1; then \
    uv run --with certifi --with numpy --with scikit-learn --with pyarrow \
      python experiments/intent-classifier/train_agent_negative_feedback.py \
        --holdout-pattern '$HOLDOUT_PATTERN' \
        --precision-floor '$PRECISION_FLOOR' \
        --public-weight '$PUBLIC_WEIGHT' \
        --prefix-field-sets '$PREFIX_FIELD_SETS' \
        --feature-sizes '$FEATURE_SIZES' \
        --c-values '$C_VALUES' \
        --class-weights '$CLASS_WEIGHTS' \
        --report '$REMOTE_REPORT' \
        --json-output '$REMOTE_JSON'; \
  else \
    python3 experiments/intent-classifier/train_agent_negative_feedback.py \
        --holdout-pattern '$HOLDOUT_PATTERN' \
        --precision-floor '$PRECISION_FLOOR' \
        --public-weight '$PUBLIC_WEIGHT' \
        --prefix-field-sets '$PREFIX_FIELD_SETS' \
        --feature-sizes '$FEATURE_SIZES' \
        --c-values '$C_VALUES' \
        --class-weights '$CLASS_WEIGHTS' \
        --report '$REMOTE_REPORT' \
        --json-output '$REMOTE_JSON'; \
  fi"

rsync -az "$REMOTE_HOST:$REMOTE_DIR/$REMOTE_REPORT" \
  "$REPO/feedback/intent-classifier/"
rsync -az "$REMOTE_HOST:$REMOTE_DIR/$REMOTE_JSON" \
  "$REPO/feedback/intent-classifier/"

echo "$REPO/$REMOTE_REPORT"
echo "$REPO/$REMOTE_JSON"
