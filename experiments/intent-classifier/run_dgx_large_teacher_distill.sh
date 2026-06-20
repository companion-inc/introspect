#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
REMOTE_HOST="${INTROSPECT_DGX_HOST:-dgx}"
REMOTE_DIR="${INTROSPECT_DGX_REPO:-/home/advaitpaliwal/introspect}"
MODEL_ID="${INTROSPECT_INTENT_TEACHER_MODEL_ID:-Qwen/Qwen3-Next-80B-A3B-Instruct-FP8}"
SERVED_MODEL="${INTROSPECT_INTENT_SERVED_MODEL:-introspect-teacher}"
RUN_NAME="${INTROSPECT_INTENT_RUN_NAME:-qwen3-next-80b-fp8-round10-large-teacher}"
PORT="${INTROSPECT_INTENT_PORT:-8002}"
ENDPOINT="${INTROSPECT_INTENT_ENDPOINT:-http://127.0.0.1:${PORT}/v1/chat/completions}"
LABEL_INPUT="${INTROSPECT_INTENT_LABEL_INPUT:-feedback/intent-classifier/large-teacher-queue-round10.jsonl}"
LABEL_LIMIT="${INTROSPECT_INTENT_LABEL_LIMIT:-0}"
WORKERS="${INTROSPECT_INTENT_WORKERS:-1}"
BATCH_SIZE="${INTROSPECT_INTENT_BATCH_SIZE:-1}"
MAX_CHARS="${INTROSPECT_INTENT_MAX_CHARS:-1800}"
HOLDOUT_PATTERN="${INTROSPECT_INTENT_HOLDOUT_PATTERN:-*round9*.jsonl}"
TEACHER_WEIGHT="${INTROSPECT_INTENT_TEACHER_WEIGHT:-0.05}"
VLLM_EXTRA_ARGS="${INTROSPECT_INTENT_VLLM_ARGS:---max-model-len 4096 --gpu-memory-utilization 0.90}"
VLLM_DOCKER_IMAGE="${INTROSPECT_INTENT_VLLM_DOCKER_IMAGE:-vllm/vllm-openai:cu130-nightly}"
VLLM_CONTAINER="${INTROSPECT_INTENT_VLLM_CONTAINER:-introspect-teacher-vllm}"
REMOTE_HF_CACHE="${INTROSPECT_INTENT_HF_CACHE:-/home/advaitpaliwal/.cache/huggingface}"
PREFETCH_MODEL="${INTROSPECT_INTENT_PREFETCH_MODEL:-1}"
PREFIX_FIELDS="${INTROSPECT_INTENT_PREFIX_FIELDS:-source}"
FEATURE_SIZES="${INTROSPECT_INTENT_FEATURE_SIZES:-30000,60000,90000}"
C_VALUES="${INTROSPECT_INTENT_C_VALUES:-0.5,1.0,2.0,4.0}"
CLASS_WEIGHTS="${INTROSPECT_INTENT_CLASS_WEIGHTS:-none,balanced}"
PRECISION_FLOOR="${INTROSPECT_INTENT_PRECISION_FLOOR:-0.95}"
REMOTE_LABELS="feedback/intent-classifier/large-teacher-${RUN_NAME}.jsonl"
LOCAL_LABELS="$REPO/$REMOTE_LABELS"
LOCAL_REPORT="$REPO/feedback/intent-classifier/distilled-tfidf-student-${RUN_NAME}-report.md"
LOCAL_JSON="$REPO/feedback/intent-classifier/distilled-tfidf-student-${RUN_NAME}.json"

# Canonical path: run a large instruction teacher on the DGX/Spark, label private
# rows there, then train and export the compact TF-IDF student locally. Override
# INTROSPECT_INTENT_TEACHER_MODEL_ID for a larger multi-Spark/cloud teacher; the
# runtime hook must still use only the exported student JSON.

if [ ! -f "$REPO/$LABEL_INPUT" ]; then
  python3 "$REPO/experiments/intent-classifier/prepare_large_teacher_queue.py" --output "$REPO/$LABEL_INPUT"
fi

ssh -o ConnectTimeout=8 -o ConnectionAttempts=1 "$REMOTE_HOST" "mkdir -p '$REMOTE_DIR/experiments/intent-classifier' '$REMOTE_DIR/feedback/intent-classifier/subagent-labels' '$(dirname "$REMOTE_DIR/$LABEL_INPUT")'"

rsync -az "$REPO/experiments/intent-classifier/label_with_qwen_batch.py" \
  "$REMOTE_HOST:$REMOTE_DIR/experiments/intent-classifier/label_with_qwen_batch.py"
rsync -az "$REPO/$LABEL_INPUT" \
  "$REMOTE_HOST:$REMOTE_DIR/$LABEL_INPUT"
rsync -az "$REPO/feedback/intent-classifier/subagent-labels/" \
  "$REMOTE_HOST:$REMOTE_DIR/feedback/intent-classifier/subagent-labels/"

ssh "$REMOTE_HOST" \
  "REMOTE_DIR='$REMOTE_DIR' MODEL_ID='$MODEL_ID' SERVED_MODEL='$SERVED_MODEL' RUN_NAME='$RUN_NAME' PORT='$PORT' ENDPOINT='$ENDPOINT' LABEL_INPUT='$LABEL_INPUT' LABEL_LIMIT='$LABEL_LIMIT' WORKERS='$WORKERS' BATCH_SIZE='$BATCH_SIZE' MAX_CHARS='$MAX_CHARS' REMOTE_LABELS='$REMOTE_LABELS' VLLM_EXTRA_ARGS='$VLLM_EXTRA_ARGS' VLLM_DOCKER_IMAGE='$VLLM_DOCKER_IMAGE' VLLM_CONTAINER='$VLLM_CONTAINER' REMOTE_HF_CACHE='$REMOTE_HF_CACHE' PREFETCH_MODEL='$PREFETCH_MODEL' bash -s" <<'REMOTE'
set -euo pipefail
cd "$REMOTE_DIR"
mkdir -p feedback/intent-classifier
base_url="${ENDPOINT%/chat/completions}"
models_url="${base_url}/models"
log_path="feedback/intent-classifier/vllm-${RUN_NAME}.log"
server_pid=""
server_mode=""

server_matches() {
  local payload
  payload="$(curl -fsS "$models_url" 2>/dev/null)" || return 1
  SERVER_MODELS_PAYLOAD="$payload" python3 - "$SERVED_MODEL" "$MODEL_ID" <<'PY'
import json
import os
import sys

served_model = sys.argv[1]
model_id = sys.argv[2]

try:
    payload = json.loads(os.environ["SERVER_MODELS_PAYLOAD"])
except Exception:
    sys.exit(1)

for row in payload.get("data", []):
    values = {str(row.get("id", "")), str(row.get("root", ""))}
    if served_model in values or model_id in values:
        sys.exit(0)
sys.exit(1)
PY
}

read_hf_token() {
  if [ -n "${HF_TOKEN:-}" ]; then
    printf '%s' "$HF_TOKEN"
    return 0
  fi
  if command -v docker >/dev/null 2>&1; then
    docker inspect vllm --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | sed -n 's/^HF_TOKEN=//p' \
      | head -1
  fi
}

prefetch_model() {
  [ "$PREFETCH_MODEL" = "1" ] || return 0
  command -v docker >/dev/null 2>&1 || return 0
  mkdir -p "$REMOTE_HF_CACHE"
  local hf_token
  hf_token="$(read_hf_token || true)"
  docker rm -f "${VLLM_CONTAINER}-prefetch" >/dev/null 2>&1 || true
  docker run --rm --name "${VLLM_CONTAINER}-prefetch" \
    -v "$REMOTE_HF_CACHE:/root/.cache/huggingface" \
    -e HF_HOME=/root/.cache/huggingface \
    -e HF_TOKEN="$hf_token" \
    -e HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}" \
    -e MODEL_ID="$MODEL_ID" \
    --entrypoint /bin/sh \
    "$VLLM_DOCKER_IMAGE" \
    -lc "python3 - <<'PY'
from huggingface_hub import snapshot_download
import os

path = snapshot_download(
    repo_id=os.environ['MODEL_ID'],
    allow_patterns=['*.json', '*.safetensors', '*.txt', 'merges.txt', 'vocab.json'],
    max_workers=int(os.environ.get('HF_MAX_WORKERS', '8')),
)
print(path)
PY"
}

launch_server() {
  if command -v vllm >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    nohup vllm serve "$MODEL_ID" --served-model-name "$SERVED_MODEL" --host 127.0.0.1 --port "$PORT" $VLLM_EXTRA_ARGS >"$log_path" 2>&1 &
    server_pid="$!"
    server_mode="process"
  elif command -v docker >/dev/null 2>&1; then
    local hf_token
    hf_token="$(read_hf_token || true)"
    docker rm -f "$VLLM_CONTAINER" >/dev/null 2>&1 || true
    # shellcheck disable=SC2086
    docker run -d --name "$VLLM_CONTAINER" \
      --gpus all \
      --network host \
      --ipc=host \
      -v "$REMOTE_HF_CACHE:/root/.cache/huggingface" \
      -e HF_HOME=/root/.cache/huggingface \
      -e HF_TOKEN="$hf_token" \
      -e TOKENIZERS_PARALLELISM=false \
      "$VLLM_DOCKER_IMAGE" \
      "$MODEL_ID" \
      --served-model-name "$SERVED_MODEL" \
      --host 127.0.0.1 \
      --port "$PORT" \
      $VLLM_EXTRA_ARGS >"$log_path"
    server_mode="docker"
  else
    # shellcheck disable=SC2086
    nohup uv run --with vllm python -m vllm.entrypoints.openai.api_server --model "$MODEL_ID" --served-model-name "$SERVED_MODEL" --host 127.0.0.1 --port "$PORT" $VLLM_EXTRA_ARGS >"$log_path" 2>&1 &
    server_pid="$!"
    server_mode="process"
  fi
}

if curl -fsS "$models_url" >/dev/null 2>&1; then
  if ! server_matches; then
    echo "A different model is already serving on $models_url; refusing to label with the wrong teacher." >&2
    curl -fsS "$models_url" >&2 || true
    exit 1
  fi
else
  prefetch_model
  launch_server
  for attempt in $(seq 1 180); do
    if server_matches; then
      break
    fi
    if [ -n "$server_pid" ] && ! kill -0 "$server_pid" 2>/dev/null; then
      tail -200 "$log_path" || true
      exit 1
    fi
    if [ "$server_mode" = "docker" ] && ! docker ps --filter "name=^/${VLLM_CONTAINER}$" --filter status=running --format '{{.Names}}' | grep -q .; then
      docker logs --tail 200 "$VLLM_CONTAINER" >&2 || tail -200 "$log_path" || true
      exit 1
    fi
    if [ "$attempt" -eq 180 ]; then
      docker logs --tail 200 "$VLLM_CONTAINER" >&2 || tail -200 "$log_path" || true
      exit 1
    fi
    sleep 5
  done
fi
python3 experiments/intent-classifier/label_with_qwen_batch.py \
  --input "$LABEL_INPUT" \
  --output "$REMOTE_LABELS" \
  --endpoint "$ENDPOINT" \
  --model "$SERVED_MODEL" \
  --limit "$LABEL_LIMIT" \
  --workers "$WORKERS" \
  --batch-size "$BATCH_SIZE" \
  --max-chars "$MAX_CHARS" \
  --progress-every 500
REMOTE

rsync -az "$REMOTE_HOST:$REMOTE_DIR/$REMOTE_LABELS" "$LOCAL_LABELS"

uv run --with numpy --with scikit-learn python "$REPO/experiments/intent-classifier/train_distilled_tfidf_student.py" \
  --holdout-pattern "$HOLDOUT_PATTERN" \
  --teacher-labels "$LOCAL_LABELS" \
  --teacher-weight "$TEACHER_WEIGHT" \
  --precision-floor "$PRECISION_FLOOR" \
  --prefix-fields "$PREFIX_FIELDS" \
  --feature-sizes "$FEATURE_SIZES" \
  --c-values "$C_VALUES" \
  --class-weights "$CLASS_WEIGHTS" \
  --report "$LOCAL_REPORT" \
  --json-output "$LOCAL_JSON"

echo "$LOCAL_REPORT"
