#!/usr/bin/env bash
# Serve Ternary Bonsai 2 27B with MTP on an 8 GB NVIDIA card.
# Measured 65-73 tok/s at 32K context on an RTX 5060.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

MODEL_DIR="${MODEL_DIR:-$HOME/models/bonsai2}"
# Reasoning profile for AGENT workloads (see RECIPE.md). For single-shot
# generation tasks, pass --reasoning off instead, or send per-request
# chat_template_kwargs {"enable_thinking": false}.
MODEL="${MODEL:-$MODEL_DIR/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"
KVMC="${KVMC:-$MODEL_DIR/kv-mean-center.gguf}"
CTX="${CTX:-32768}"
PORT="${PORT:-18199}"
HOST="${HOST:-127.0.0.1}"

[[ -f "$MODEL" ]] || { echo "error: model not found: $MODEL" >&2; exit 1; }
[[ -f "$KVMC"  ]] || { echo "error: kv bias not found: $KVMC (run scripts/make-kv-bias.sh)" >&2; exit 1; }

# MTP must be strictly lossless
export GGML_CUDA_BATCH_INVARIANT=1

exec "$BIN/llama-server" \
  -m "$MODEL" \
  -ngl 99 -fa on \
  -c "$CTX" -np 1 \
  -ctk q4_0 -ctv q4_0 \
  --kv-mean-center "$KVMC" \
  --jinja \
  --reasoning-effort "${REASONING_EFFORT:-low}" \
  --reasoning-budget "${REASONING_BUDGET:-4096}" \
  --spec-type draft-mtp --spec-draft-n-max 1 \
  --temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0 \
  --presence-penalty 1.5 --frequency-penalty 0.0 --repeat-penalty 1.0 \
  --host "$HOST" --port "$PORT" \
  "$@"
