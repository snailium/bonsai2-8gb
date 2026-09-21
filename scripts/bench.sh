#!/usr/bin/env bash
# Reproduce the numbers in RECIPE.md.
# Stop any running llama-server first - two processes will contend for the GPU
# and silently halve throughput.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$DIR/bin"
export LD_LIBRARY_PATH="$BIN${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

MODEL_DIR="${MODEL_DIR:-$HOME/models/bonsai2}"
MODEL="${MODEL:-$MODEL_DIR/Ternary-Bonsai-2-27B-PTQ1_0-mtp-lean.gguf}"

if pgrep -f llama-server >/dev/null; then
  echo "warning: llama-server is running; stop it before benchmarking" >&2
fi

echo "=== kernel comparison (expect tg128 ~54 t/s on an RTX 5060) ==="
"$BIN/llama-bench" -m "$MODEL" -ngl 99 -fa 1 -ctk q4_0 -ctv q4_0 \
  -p 512 -n 128 -r 3 -d 0
